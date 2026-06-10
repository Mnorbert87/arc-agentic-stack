// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBond, IERC20} from "../src/AgentBond.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Property-based unit tests: every assertion compares the contract's effect on REAL token
///      balances against independently computed expectations, across the whole input space.
contract AgentBondFuzzTest is Test {
    AgentBond ab;
    MockERC20 usdc;

    address agent = address(0xA1);
    address enforcer = address(0xE1);
    address creditor = address(0xC1);

    uint256 constant MAX = 1_000_000_000e6; // 1e15 micro-USDC headroom, no overflow anywhere

    function setUp() public {
        usdc = new MockERC20();
        ab = new AgentBond(IERC20(address(usdc)));
        usdc.mint(agent, MAX);
        vm.prank(agent);
        usdc.approve(address(ab), type(uint256).max);
    }

    /// deposit then full withdraw is an exact round trip — the agent ends with the tokens it
    /// started with and the contract holds nothing.
    function testFuzz_depositWithdraw_exactRoundTrip(uint256 amount) public {
        amount = bound(amount, 1, MAX);
        uint256 startBal = usdc.balanceOf(agent);

        vm.startPrank(agent);
        ab.deposit(amount);
        ab.withdraw(amount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(agent), startBal, "agent lost or gained tokens");
        assertEq(usdc.balanceOf(address(ab)), 0, "contract retained tokens");
        assertEq(ab.bond(agent), 0, "bond not zeroed");
    }

    /// Whatever is locked is untouchable: withdrawing more than (bond - locked) always reverts,
    /// withdrawing exactly the free amount always succeeds.
    function testFuzz_withdraw_freeBoundIsExact(uint256 depositAmt, uint256 lockAmt) public {
        depositAmt = bound(depositAmt, 1, MAX);
        lockAmt = bound(lockAmt, 1, depositAmt);

        vm.startPrank(agent);
        ab.deposit(depositAmt);
        ab.setSlashAllowance(enforcer, lockAmt);
        vm.stopPrank();
        vm.prank(enforcer);
        ab.lock(agent, creditor, lockAmt, 0);

        uint256 free = depositAmt - lockAmt;
        if (free < depositAmt) {
            vm.prank(agent);
            vm.expectRevert(bytes("INSUFFICIENT_FREE"));
            ab.withdraw(free + 1);
        }
        if (free > 0) {
            uint256 before = usdc.balanceOf(agent);
            vm.prank(agent);
            ab.withdraw(free);
            assertEq(usdc.balanceOf(agent) - before, free, "free withdrawal paid wrong amount");
        }
    }

    /// A slash pays the creditor exactly the locked amount, the contract keeps exactly the rest,
    /// and the burned capacity does not come back to the enforcer's allowance.
    function testFuzz_slash_paysExactlyLockedAmount(uint256 depositAmt, uint256 lockAmt) public {
        depositAmt = bound(depositAmt, 1, MAX);
        lockAmt = bound(lockAmt, 1, depositAmt);

        vm.startPrank(agent);
        ab.deposit(depositAmt);
        ab.setSlashAllowance(enforcer, lockAmt);
        vm.stopPrank();
        vm.prank(enforcer);
        uint256 id = ab.lock(agent, creditor, lockAmt, 0);

        vm.prank(enforcer);
        ab.slash(id);

        assertEq(usdc.balanceOf(creditor), lockAmt, "creditor paid wrong amount");
        assertEq(usdc.balanceOf(address(ab)), depositAmt - lockAmt, "contract balance wrong");
        assertEq(ab.bond(agent), depositAmt - lockAmt, "bond not reduced by slash");
        assertEq(ab.locked(agent), 0, "locked not cleared");
        assertEq(ab.slashAllowance(agent, enforcer), 0, "slashed capacity must stay burned");
    }

    /// Release restores both the locked bond and the enforcer's revolving allowance exactly,
    /// and moves no tokens at all.
    function testFuzz_release_restoresExactCapacity(uint256 depositAmt, uint256 lockAmt) public {
        depositAmt = bound(depositAmt, 1, MAX);
        lockAmt = bound(lockAmt, 1, depositAmt);

        vm.startPrank(agent);
        ab.deposit(depositAmt);
        ab.setSlashAllowance(enforcer, lockAmt);
        vm.stopPrank();
        vm.prank(enforcer);
        uint256 id = ab.lock(agent, creditor, lockAmt, 0);

        uint256 contractBal = usdc.balanceOf(address(ab));
        vm.prank(enforcer);
        ab.release(id);

        assertEq(usdc.balanceOf(address(ab)), contractBal, "release must move no tokens");
        assertEq(ab.locked(agent), 0, "locked not cleared");
        assertEq(ab.slashAllowance(agent, enforcer), lockAmt, "allowance not restored");
        assertEq(ab.bond(agent), depositAmt, "bond must be untouched by release");
    }

    /// ACCESS FUZZ: an arbitrary address that is not the enforcer can neither release nor slash
    /// an active obligation, and cannot lock without an allowance grant.
    function testFuzz_stranger_cannotTouchObligation(address rando, uint256 amt) public {
        amt = bound(amt, 1, MAX);
        vm.startPrank(agent);
        ab.deposit(amt);
        ab.setSlashAllowance(enforcer, amt);
        vm.stopPrank();
        vm.prank(enforcer);
        uint256 id = ab.lock(agent, creditor, amt, 0);

        vm.assume(rando != enforcer);

        vm.prank(rando);
        vm.expectRevert(); // NOT_AUTHORIZED (also covers agent: deadline == 0)
        ab.release(id);

        vm.prank(rando);
        vm.expectRevert(bytes("NOT_ENFORCER"));
        ab.slash(id);

        if (rando != address(0)) {
            vm.prank(rando);
            vm.expectRevert(bytes("ALLOWANCE"));
            ab.lock(agent, creditor, 1, 0);
        }
    }
}
