// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitStake, IERC20} from "../src/CommitStake.sol";
import {FeeToken} from "./mocks/AttackTokens.sol";

/// @notice Own-book solvency invariant under a 10% fee-on-transfer token. Unlike the 1:1
///         MockERC20 invariant (CommitStakeAdversarial.t.sol), the ghost ledger here is the
///         contract's OWN booked amounts — which, thanks to balance-delta accounting, are the
///         real balanceOf deltas. The probe (CommitStakeFeeTokenProbe.t.sol) showed a 1:1
///         flow-conservation ghost breaks under a fee token; this run proves the own-book
///         property the NatSpec actually claims: escrow balance == sum of open booked stakes,
///         for any interleaving, even when the token skims every transfer.
contract FeeSolvencyHandler is Test {
    CommitStake public cs;
    FeeToken public fee;
    uint256[] public ids;
    address constant VERIFIER = address(0xBEEF);
    address constant BENEF = address(0xCAFE);

    address[] internal actors = [address(0x1), address(0x2), address(0x3), address(0x4)];

    constructor(CommitStake _cs, FeeToken _fee) {
        cs = _cs;
        fee = _fee;
    }

    function create(uint256 actorSeed, uint256 amount, uint64 dl) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1_000_000);
        dl = uint64(bound(dl, block.timestamp + 1, block.timestamp + 365 days));
        fee.mint(actor, amount);
        vm.startPrank(actor);
        fee.approve(address(cs), amount);
        // create() reverts NO_FUNDS when the 10% skim rounds the delta to zero — that is the
        // contract refusing to book a stake it never received, so just skip those amounts
        try cs.create(VERIFIER, BENEF, amount, dl, "x") returns (uint256 id) {
            ids.push(id);
        } catch {}
        vm.stopPrank();
    }

    function resolve(uint256 idSeed, bool passed) external {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        if (cs.get(id).status != CommitStake.Status.Active) return;
        if (block.timestamp > cs.get(id).deadline) return;
        vm.prank(VERIFIER);
        cs.resolve(id, passed);
    }

    function claim(uint256 idSeed) external {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        CommitStake.Commitment memory c = cs.get(id);
        if (c.status != CommitStake.Status.Passed) return;
        vm.prank(c.staker);
        cs.claim(id);
    }

    function slashExpired(uint256 idSeed) external {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        if (cs.get(id).status != CommitStake.Status.Active) return;
        if (block.timestamp <= cs.get(id).deadline) return;
        cs.slashExpired(id);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 30 days));
    }

    /// Sum of BOOKED stakes still held (Active = locked, Passed = awaiting claim). These are
    /// the contract's own balance-delta figures, not the pre-fee requested amounts.
    function openStakeSum() external view returns (uint256 sum) {
        for (uint256 i = 0; i < ids.length; i++) {
            CommitStake.Commitment memory c = cs.get(ids[i]);
            if (c.status == CommitStake.Status.Active || c.status == CommitStake.Status.Passed) {
                sum += c.amount;
            }
        }
    }
}

contract CommitStakeFeeInvariantTest is Test {
    CommitStake cs;
    FeeToken fee;
    FeeSolvencyHandler handler;

    function setUp() public {
        fee = new FeeToken(1000); // 10% skim on every transfer
        cs = new CommitStake(IERC20(address(fee)));
        handler = new FeeSolvencyHandler(cs, fee);
        targetContract(address(handler));
    }

    /// By its own books the escrow is exactly solvent under a fee token: it holds precisely
    /// what it still owes on open commitments — never less (insolvency), never more (stuck funds).
    function invariant_solvent_byOwnBooks_feeToken() public view {
        assertEq(fee.balanceOf(address(cs)), handler.openStakeSum());
    }
}
