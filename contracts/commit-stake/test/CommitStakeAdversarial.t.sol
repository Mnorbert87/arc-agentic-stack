// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitStake, IERC20} from "../src/CommitStake.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantToken, FeeToken, NoReturnToken} from "./mocks/AttackTokens.sol";

/// @notice Adversarial suite: reentrancy, fee-on-transfer custody, non-bool tokens,
///         access-control fuzzing, and a solvency invariant. The goal is to BREAK the
///         escrow; everything green = the escrow holds.
contract CommitStakeAdversarialTest is Test {
    uint64 deadline;

    function setUp() public {
        deadline = uint64(block.timestamp + 7 days);
    }

    // ----------------------------------------------------------------------------------
    // 1. Reentrancy: a malicious token reenters claim()/slashExpired() during payout.
    //    Must NOT double-pay; reentrant call must revert.
    // ----------------------------------------------------------------------------------
    function test_reentrancy_noDoublePay_onClaim() public {
        ReentrantToken evil = new ReentrantToken();
        CommitStake cs = new CommitStake(IERC20(address(evil)));

        address staker = address(this);
        evil.mint(staker, 10_000_000);
        evil.approve(address(cs), 10_000_000);

        uint256 id = cs.create(address(0xBEEF), address(0xCAFE), 10_000_000, deadline, "g");
        evil.setTarget(cs, id); // arm the reentry on the next outgoing transfer

        // verifier passes -> staker claims -> token.transfer reenters
        vm.prank(address(0xBEEF));
        cs.resolve(id, true);
        cs.claim(id);

        assertTrue(evil.reentryAttempted(), "attacker token never fired");
        assertTrue(evil.reentryReverted(), "reentrant claim was NOT blocked");
        // exactly the stake, never twice
        assertEq(evil.balanceOf(staker), 10_000_000, "double pay / wrong payout");
        assertEq(evil.balanceOf(address(cs)), 0, "escrow not drained to exactly zero");
        assertEq(uint8(cs.get(id).status), uint8(CommitStake.Status.Claimed));
    }

    function test_reentrancy_noDoublePay_onSlash() public {
        ReentrantToken evil = new ReentrantToken();
        CommitStake cs = new CommitStake(IERC20(address(evil)));

        evil.mint(address(this), 10_000_000);
        evil.approve(address(cs), 10_000_000);
        uint256 id = cs.create(address(0xBEEF), address(0xCAFE), 10_000_000, deadline, "g");
        evil.setTarget(cs, id);

        vm.prank(address(0xBEEF));
        cs.resolve(id, false); // slash to beneficiary -> token.transfer reenters

        assertTrue(evil.reentryReverted(), "reentry not blocked on slash");
        assertEq(evil.balanceOf(address(0xCAFE)), 10_000_000, "beneficiary wrong amount");
        assertEq(evil.balanceOf(address(cs)), 0);
        assertEq(uint8(cs.get(id).status), uint8(CommitStake.Status.Slashed));
    }

    // ----------------------------------------------------------------------------------
    // 2. Fee-on-transfer custody: stake recorded = funds actually received, so two stakers
    //    can both fully exit. Without balance-delta custody the second claim would revert.
    // ----------------------------------------------------------------------------------
    function test_feeOnTransfer_solvent_bothCanExit() public {
        FeeToken fee = new FeeToken(1000); // 10% skim
        CommitStake cs = new CommitStake(IERC20(address(fee)));

        address a = address(0xA1);
        address b = address(0xB2);
        fee.mint(a, 10_000_000);
        fee.mint(b, 10_000_000);

        vm.prank(a);
        fee.approve(address(cs), 10_000_000);
        vm.prank(b);
        fee.approve(address(cs), 10_000_000);

        vm.prank(a);
        uint256 idA = cs.create(address(0xBEEF), address(0xCAFE), 10_000_000, deadline, "a");
        vm.prank(b);
        uint256 idB = cs.create(address(0xBEEF), address(0xCAFE), 10_000_000, deadline, "b");

        // each commitment recorded only the 9_000_000 that actually arrived
        assertEq(cs.get(idA).amount, 9_000_000, "A custody not net-of-fee");
        assertEq(cs.get(idB).amount, 9_000_000, "B custody not net-of-fee");
        assertEq(fee.balanceOf(address(cs)), 18_000_000, "escrow holds both net stakes");

        // both pass and both can fully claim — no insolvency
        vm.startPrank(address(0xBEEF));
        cs.resolve(idA, true);
        cs.resolve(idB, true);
        vm.stopPrank();

        vm.prank(a);
        cs.claim(idA);
        vm.prank(b);
        cs.claim(idB); // would revert BALANCE if custody were naive

        assertEq(uint8(cs.get(idB).status), uint8(CommitStake.Status.Claimed));
    }

    // ----------------------------------------------------------------------------------
    // 3. Non-bool (USDT-style) token: safe-transfer helpers must tolerate empty returndata.
    // ----------------------------------------------------------------------------------
    function test_noReturnToken_worksEndToEnd() public {
        NoReturnToken t = new NoReturnToken();
        CommitStake cs = new CommitStake(IERC20(address(t)));

        t.mint(address(this), 10_000_000);
        t.approve(address(cs), 10_000_000);
        uint256 id = cs.create(address(0xBEEF), address(0xCAFE), 10_000_000, deadline, "g");

        vm.prank(address(0xBEEF));
        cs.resolve(id, true);
        cs.claim(id);
        assertEq(t.balanceOf(address(this)), 10_000_000);
    }

    // ----------------------------------------------------------------------------------
    // 4. Access-control fuzzing: only verifier resolves, only staker claims.
    // ----------------------------------------------------------------------------------
    function testFuzz_nonVerifier_cannotResolve(address rando) public {
        (CommitStake cs, uint256 id) = _freshCommitment();
        vm.assume(rando != address(0xBEEF));
        vm.prank(rando);
        vm.expectRevert("NOT_VERIFIER");
        cs.resolve(id, true);
    }

    function testFuzz_nonStaker_cannotClaim(address rando) public {
        (CommitStake cs, uint256 id) = _freshCommitment();
        vm.prank(address(0xBEEF));
        cs.resolve(id, true);
        vm.assume(rando != address(this));
        vm.prank(rando);
        vm.expectRevert("NOT_STAKER");
        cs.claim(id);
    }

    function _freshCommitment() internal returns (CommitStake cs, uint256 id) {
        MockERC20 usdc = new MockERC20();
        cs = new CommitStake(IERC20(address(usdc)));
        usdc.mint(address(this), 10_000_000);
        usdc.approve(address(cs), 10_000_000);
        id = cs.create(address(0xBEEF), address(0xCAFE), 10_000_000, deadline, "g");
    }
}

// ======================================================================================
// 5. Solvency invariant: across random create/resolve/claim/slash from many actors,
//    the escrow balance must always equal the sum of still-open (Active+Passed) stakes.
// ======================================================================================
contract SolvencyHandler is Test {
    CommitStake public cs;
    MockERC20 public usdc;
    uint256[] public ids;
    address constant VERIFIER = address(0xBEEF);
    address constant BENEF = address(0xCAFE);

    address[] internal actors = [address(0x1), address(0x2), address(0x3), address(0x4)];

    constructor(CommitStake _cs, MockERC20 _usdc) {
        cs = _cs;
        usdc = _usdc;
    }

    function create(uint256 actorSeed, uint256 amount, uint64 dl) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1_000_000);
        dl = uint64(bound(dl, block.timestamp + 1, block.timestamp + 365 days));
        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(cs), amount);
        uint256 id = cs.create(VERIFIER, BENEF, amount, dl, "x");
        vm.stopPrank();
        ids.push(id);
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

    /// Sum of stakes still held by the contract (Active = locked, Passed = awaiting claim).
    function openStakeSum() external view returns (uint256 sum) {
        for (uint256 i = 0; i < ids.length; i++) {
            CommitStake.Commitment memory c = cs.get(ids[i]);
            if (c.status == CommitStake.Status.Active || c.status == CommitStake.Status.Passed) {
                sum += c.amount;
            }
        }
    }
}

contract CommitStakeInvariantTest is Test {
    CommitStake cs;
    MockERC20 usdc;
    SolvencyHandler handler;

    function setUp() public {
        usdc = new MockERC20();
        cs = new CommitStake(IERC20(address(usdc)));
        handler = new SolvencyHandler(cs, usdc);
        targetContract(address(handler));
    }

    /// The escrow is never insolvent and never over-collateralised: balance == open stakes.
    function invariant_solvent() public view {
        assertEq(usdc.balanceOf(address(cs)), handler.openStakeSum());
    }
}
