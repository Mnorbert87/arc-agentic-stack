// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitStake, IERC20} from "../src/CommitStake.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Property-based unit tests over the full parameter space: every lifecycle ends with the
///      stake on exactly one side, verified against REAL token balances.
contract CommitStakeFuzzTest is Test {
    CommitStake cs;
    MockERC20 usdc;

    address staker = address(0xA1);
    address verifier = address(0xF1);
    address beneficiary = address(0xBE1);

    uint256 constant MAX = 1_000_000_000e6;

    function setUp() public {
        usdc = new MockERC20();
        cs = new CommitStake(IERC20(address(usdc)));
        usdc.mint(staker, MAX);
        vm.prank(staker);
        usdc.approve(address(cs), type(uint256).max);
        vm.warp(1_000_000);
    }

    /// Any pass lifecycle returns exactly the stake to the staker; the beneficiary gets nothing
    /// and the contract ends empty.
    function testFuzz_passLifecycle_stakerMadeWhole(uint256 amount, uint64 deadlineOffset) public {
        amount = bound(amount, 1, MAX);
        deadlineOffset = uint64(bound(deadlineOffset, 1, 365 days));
        uint256 startBal = usdc.balanceOf(staker);

        vm.prank(staker);
        uint256 id =
            cs.create(verifier, beneficiary, amount, uint64(block.timestamp) + deadlineOffset, "g");
        vm.prank(verifier);
        cs.resolve(id, true);
        vm.prank(staker);
        cs.claim(id);

        assertEq(usdc.balanceOf(staker), startBal, "staker not made exactly whole");
        assertEq(usdc.balanceOf(beneficiary), 0, "beneficiary paid on a pass");
        assertEq(usdc.balanceOf(address(cs)), 0, "escrow retained funds");
    }

    /// Any fail lifecycle pays exactly the stake to the beneficiary; the staker can never get
    /// anything back afterwards.
    function testFuzz_failLifecycle_beneficiaryPaidOnce(uint256 amount, uint64 deadlineOffset)
        public
    {
        amount = bound(amount, 1, MAX);
        deadlineOffset = uint64(bound(deadlineOffset, 1, 365 days));

        vm.prank(staker);
        uint256 id =
            cs.create(verifier, beneficiary, amount, uint64(block.timestamp) + deadlineOffset, "g");
        vm.prank(verifier);
        cs.resolve(id, false);

        assertEq(usdc.balanceOf(beneficiary), amount, "beneficiary paid wrong amount");
        assertEq(usdc.balanceOf(address(cs)), 0, "escrow retained funds");

        // the slashed stake is gone for the staker — no claim path exists
        vm.prank(staker);
        vm.expectRevert(bytes("NOT_PASSED"));
        cs.claim(id);
    }

    /// A silent verifier can never freeze funds: past the deadline ANY caller pushes the stake
    /// to the beneficiary, exactly once, and the verifier can no longer flip the outcome.
    function testFuzz_silentVerifier_expiryPaysBeneficiary(
        uint256 amount,
        uint64 deadlineOffset,
        uint64 lateBy,
        address anyCaller
    ) public {
        amount = bound(amount, 1, MAX);
        deadlineOffset = uint64(bound(deadlineOffset, 1, 365 days));
        lateBy = uint64(bound(lateBy, 1, 365 days));

        vm.prank(staker);
        uint256 id =
            cs.create(verifier, beneficiary, amount, uint64(block.timestamp) + deadlineOffset, "g");

        vm.warp(block.timestamp + uint256(deadlineOffset) + lateBy);

        vm.prank(anyCaller);
        cs.slashExpired(id);
        assertEq(usdc.balanceOf(beneficiary), amount, "expiry slash paid wrong amount");

        // second trigger is impossible
        vm.prank(anyCaller);
        vm.expectRevert(bytes("NOT_ACTIVE"));
        cs.slashExpired(id);

        // and a late verifier cannot resurrect the commitment
        vm.prank(verifier);
        vm.expectRevert(bytes("NOT_ACTIVE"));
        cs.resolve(id, true);
    }

    /// Whatever the outcome flag and timing, the stake ends up on exactly ONE side and the two
    /// payouts sum to exactly the stake. (The XOR property as a single fuzz surface.)
    function testFuzz_exactlyOneSideEverPaid(uint256 amount, bool passed, bool resolveInTime)
        public
    {
        amount = bound(amount, 1, MAX);
        uint64 deadline = uint64(block.timestamp) + 1 days;

        vm.prank(staker);
        uint256 id = cs.create(verifier, beneficiary, amount, deadline, "g");
        uint256 stakerAfterStake = usdc.balanceOf(staker);

        if (resolveInTime) {
            vm.prank(verifier);
            cs.resolve(id, passed);
            if (passed) {
                vm.prank(staker);
                cs.claim(id);
            }
        } else {
            vm.warp(uint256(deadline) + 1);
            cs.slashExpired(id);
        }

        uint256 stakerGot = usdc.balanceOf(staker) - stakerAfterStake;
        uint256 beneficiaryGot = usdc.balanceOf(beneficiary);

        assertTrue(stakerGot == 0 || beneficiaryGot == 0, "both sides paid");
        assertEq(stakerGot + beneficiaryGot, amount, "payouts != stake");
        assertEq(usdc.balanceOf(address(cs)), 0, "escrow retained funds");
    }
}
