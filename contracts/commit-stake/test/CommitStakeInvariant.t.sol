// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitStake, IERC20} from "../src/CommitStake.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Drives CommitStake through random create/resolve/claim/slashExpired/warp sequences.
///      Every payout is measured from REAL ERC-20 balance deltas of the staker / beneficiary,
///      attributed per commitment. The invariants prove the core escrow property: each stake is
///      paid out to exactly ONE side (staker XOR beneficiary), exactly once, in full — and the
///      contract's real balance always equals what it still owes.
contract CommitStakeHandler is Test {
    CommitStake public cs;
    MockERC20 public usdc;

    address[2] public stakers = [address(0xA1), address(0xA2)];
    address public verifier = address(0xF1);
    address public beneficiary = address(0xBE1); // disjoint from stakers/verifier

    struct Ghost {
        address staker;
        uint256 amountIn; // tokens that actually entered escrow at create
        uint256 stakerPaid; // tokens that actually reached the staker (claim)
        uint256 beneficiaryPaid; // tokens that actually reached the beneficiary (slash)
        uint64 deadline;
    }

    uint256[] public ids;
    mapping(uint256 => Ghost) public ghosts;

    constructor(CommitStake _cs, MockERC20 _usdc) {
        cs = _cs;
        usdc = _usdc;
        for (uint256 i; i < stakers.length; i++) {
            usdc.mint(stakers[i], 1_000_000_000e6);
            vm.prank(stakers[i]);
            usdc.approve(address(cs), type(uint256).max);
        }
    }

    function create(uint256 si, uint256 amt, uint64 deadlineOffset) public {
        address s = stakers[si % stakers.length];
        amt = bound(amt, 1, 1_000_000e6);
        if (usdc.balanceOf(s) < amt) return;
        uint64 deadline = uint64(block.timestamp) + (deadlineOffset % 30 days) + 1;

        uint256 escrowBefore = usdc.balanceOf(address(cs));
        vm.prank(s);
        uint256 id = cs.create(verifier, beneficiary, amt, deadline, "inv");
        ids.push(id);
        ghosts[id] = Ghost({
            staker: s,
            amountIn: usdc.balanceOf(address(cs)) - escrowBefore,
            stakerPaid: 0,
            beneficiaryPaid: 0,
            deadline: deadline
        });
    }

    function resolve(uint256 idx, bool passed) public {
        if (ids.length == 0) return;
        uint256 id = ids[idx % ids.length];
        Ghost storage g = ghosts[id];
        CommitStake.Commitment memory c = cs.get(id);
        if (c.status != CommitStake.Status.Active || block.timestamp > c.deadline) return;
        uint256 benBefore = usdc.balanceOf(beneficiary);
        vm.prank(verifier);
        cs.resolve(id, passed);
        g.beneficiaryPaid += usdc.balanceOf(beneficiary) - benBefore;
    }

    function claim(uint256 idx) public {
        if (ids.length == 0) return;
        uint256 id = ids[idx % ids.length];
        Ghost storage g = ghosts[id];
        if (cs.get(id).status != CommitStake.Status.Passed) return;
        uint256 before = usdc.balanceOf(g.staker);
        vm.prank(g.staker);
        cs.claim(id);
        g.stakerPaid += usdc.balanceOf(g.staker) - before;
    }

    function slashExpired(uint256 idx, uint256 callerSeed) public {
        if (ids.length == 0) return;
        uint256 id = ids[idx % ids.length];
        Ghost storage g = ghosts[id];
        CommitStake.Commitment memory c = cs.get(id);
        if (c.status != CommitStake.Status.Active || block.timestamp <= c.deadline) return;
        uint256 benBefore = usdc.balanceOf(beneficiary);
        // literally anyone may trigger it — fuzz the caller
        vm.prank(address(uint160(0x1000 + (callerSeed % 1000))));
        cs.slashExpired(id);
        g.beneficiaryPaid += usdc.balanceOf(beneficiary) - benBefore;
    }

    /// Time only moves forward (Arc timestamps are non-decreasing).
    function warp(uint256 delta) public {
        vm.warp(block.timestamp + bound(delta, 0, 10 days));
    }

    // --- aggregation for the invariants ---

    function count() external view returns (uint256) {
        return ids.length;
    }

    function sumEscrowOwed() external view returns (uint256 s) {
        for (uint256 i; i < ids.length; i++) {
            Ghost storage g = ghosts[ids[i]];
            s += g.amountIn - g.stakerPaid - g.beneficiaryPaid;
        }
    }
}

contract CommitStakeInvariantTest is Test {
    CommitStake cs;
    MockERC20 usdc;
    CommitStakeHandler h;

    function setUp() public {
        usdc = new MockERC20();
        cs = new CommitStake(IERC20(address(usdc)));
        h = new CommitStakeHandler(cs, usdc);
        targetContract(address(h));
    }

    /// EXACTLY-ONE PAYOUT: for every commitment, the stake reaches the staker XOR the
    /// beneficiary — never both, never more than the stake, and a terminal state implies the
    /// full amount went to the one correct side. Double payout is impossible.
    function invariant_exactlyOnePayout() public view {
        for (uint256 i; i < h.count(); i++) {
            uint256 id = h.ids(i);
            (, uint256 amountIn, uint256 stakerPaid, uint256 beneficiaryPaid,) = h.ghosts(id);

            assertTrue(stakerPaid == 0 || beneficiaryPaid == 0, "BOTH sides were paid");
            assertLe(stakerPaid + beneficiaryPaid, amountIn, "paid out more than the stake");

            CommitStake.Status st = cs.get(id).status;
            if (st == CommitStake.Status.Claimed) {
                assertEq(stakerPaid, amountIn, "claimed but staker not fully paid");
                assertEq(beneficiaryPaid, 0, "claimed but beneficiary also paid");
            } else if (st == CommitStake.Status.Slashed) {
                assertEq(beneficiaryPaid, amountIn, "slashed but beneficiary not fully paid");
                assertEq(stakerPaid, 0, "slashed but staker also paid");
            } else {
                // Active or Passed: escrow still holds the funds, nobody has been paid
                assertEq(stakerPaid + beneficiaryPaid, 0, "payout before terminal state");
            }
        }
    }

    /// SOLVENCY (pure flow): the contract's real token balance equals what it still owes —
    /// everything that entered minus everything that verifiably left to either side.
    function invariant_solvent_flowConservation() public view {
        assertEq(
            usdc.balanceOf(address(cs)),
            h.sumEscrowOwed(),
            "FLOW LEAK: balance != sum(stake - payouts)"
        );
    }
}
