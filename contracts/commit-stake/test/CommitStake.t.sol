// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitStake, IERC20} from "../src/CommitStake.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract CommitStakeTest is Test {
    CommitStake cs;
    MockERC20 usdc;

    address staker = address(0xA11CE);
    address verifier = address(0xBEEF);
    address beneficiary = address(0xCAFE);

    uint256 constant AMOUNT = 10_000_000; // 10 USDC (6 decimals)
    uint64 deadline;

    function setUp() public {
        usdc = new MockERC20();
        cs = new CommitStake(IERC20(address(usdc)));
        deadline = uint64(block.timestamp + 7 days);

        usdc.mint(staker, AMOUNT);
        vm.prank(staker);
        usdc.approve(address(cs), AMOUNT);
    }

    function _create() internal returns (uint256 id) {
        vm.prank(staker);
        id = cs.create(verifier, beneficiary, AMOUNT, deadline, "learn Hungarian, score >= 80%");
    }

    function test_create_locksFunds() public {
        uint256 id = _create();
        assertEq(usdc.balanceOf(address(cs)), AMOUNT);
        assertEq(usdc.balanceOf(staker), 0);

        CommitStake.Commitment memory c = cs.get(id);
        assertEq(c.staker, staker);
        assertEq(c.verifier, verifier);
        assertEq(c.beneficiary, beneficiary);
        assertEq(c.amount, AMOUNT);
        assertEq(uint8(c.status), uint8(CommitStake.Status.Active));
    }

    function test_pass_thenClaim_returnsStake() public {
        uint256 id = _create();

        vm.prank(verifier);
        cs.resolve(id, true);
        assertEq(uint8(cs.get(id).status), uint8(CommitStake.Status.Passed));

        vm.prank(staker);
        cs.claim(id);

        assertEq(usdc.balanceOf(staker), AMOUNT);
        assertEq(usdc.balanceOf(address(cs)), 0);
        assertEq(uint8(cs.get(id).status), uint8(CommitStake.Status.Claimed));
    }

    function test_fail_slashesToBeneficiary() public {
        uint256 id = _create();

        vm.prank(verifier);
        cs.resolve(id, false);

        assertEq(usdc.balanceOf(beneficiary), AMOUNT);
        assertEq(usdc.balanceOf(address(cs)), 0);
        assertEq(uint8(cs.get(id).status), uint8(CommitStake.Status.Slashed));
    }

    function test_expiry_anyoneCanSlash() public {
        uint256 id = _create();
        vm.warp(deadline + 1);

        // a random third party triggers it
        vm.prank(address(0xD00D));
        cs.slashExpired(id);

        assertEq(usdc.balanceOf(beneficiary), AMOUNT);
        assertEq(uint8(cs.get(id).status), uint8(CommitStake.Status.Slashed));
    }

    function test_onlyVerifierCanResolve() public {
        uint256 id = _create();
        vm.prank(staker);
        vm.expectRevert("NOT_VERIFIER");
        cs.resolve(id, true);
    }

    function test_cannotResolveAfterDeadline() public {
        uint256 id = _create();
        vm.warp(deadline + 1);
        vm.prank(verifier);
        vm.expectRevert("DEADLINE_PASSED");
        cs.resolve(id, true);
    }

    function test_cannotSlashBeforeDeadline() public {
        uint256 id = _create();
        vm.expectRevert("NOT_EXPIRED");
        cs.slashExpired(id);
    }

    function test_onlyStakerCanClaim() public {
        uint256 id = _create();
        vm.prank(verifier);
        cs.resolve(id, true);

        vm.prank(address(0xD00D));
        vm.expectRevert("NOT_STAKER");
        cs.claim(id);
    }

    function test_cannotClaimTwice() public {
        uint256 id = _create();
        vm.prank(verifier);
        cs.resolve(id, true);
        vm.prank(staker);
        cs.claim(id);

        vm.prank(staker);
        vm.expectRevert("NOT_PASSED");
        cs.claim(id);
    }

    function test_cannotDoubleResolve() public {
        uint256 id = _create();
        vm.prank(verifier);
        cs.resolve(id, false);

        vm.prank(verifier);
        vm.expectRevert("NOT_ACTIVE");
        cs.resolve(id, true);
    }

    function test_revert_zeroAmount() public {
        vm.prank(staker);
        vm.expectRevert("AMOUNT_ZERO");
        cs.create(verifier, beneficiary, 0, deadline, "x");
    }

    function test_revert_pastDeadline() public {
        vm.prank(staker);
        vm.expectRevert("DEADLINE_PAST");
        cs.create(verifier, beneficiary, AMOUNT, uint64(block.timestamp), "x");
    }
}
