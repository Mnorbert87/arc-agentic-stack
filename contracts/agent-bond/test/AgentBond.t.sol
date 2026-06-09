// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBond, IERC20} from "../src/AgentBond.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract AgentBondTest is Test {
    AgentBond bond;
    MockERC20 usdc;

    address agent = address(0xA1);
    address enforcer = address(0xE1); // a protocol contract (credit line / marketplace escrow)
    address other = address(0xE2); // a NON-approved enforcer
    address creditor = address(0xC1);

    uint256 constant UNIT = 1e6; // 1 USDC

    function setUp() public {
        usdc = new MockERC20();
        bond = new AgentBond(IERC20(address(usdc)));

        usdc.mint(agent, 1000 * UNIT);
        vm.prank(agent);
        usdc.approve(address(bond), type(uint256).max);
    }

    function _deposit(uint256 amount) internal {
        vm.prank(agent);
        bond.deposit(amount);
    }

    // --- deposit / withdraw ---

    function test_deposit_increasesBond() public {
        _deposit(100 * UNIT);
        assertEq(bond.bond(agent), 100 * UNIT);
        assertEq(bond.freeBondOf(agent), 100 * UNIT);
        assertEq(usdc.balanceOf(address(bond)), 100 * UNIT);
    }

    function test_withdraw_freeBond() public {
        _deposit(100 * UNIT);
        vm.prank(agent);
        bond.withdraw(40 * UNIT);
        assertEq(bond.bond(agent), 60 * UNIT);
        assertEq(usdc.balanceOf(agent), 940 * UNIT);
    }

    function test_withdraw_revertsOverFree() public {
        _deposit(100 * UNIT);
        vm.prank(agent);
        vm.expectRevert("INSUFFICIENT_FREE");
        bond.withdraw(101 * UNIT);
    }

    // --- allowance + lock ---

    function test_lock_consumesAllowanceAndLocksBond() public {
        _deposit(100 * UNIT);
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 50 * UNIT);

        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 30 * UNIT, 0);

        assertEq(id, 1);
        assertEq(bond.locked(agent), 30 * UNIT);
        assertEq(bond.freeBondOf(agent), 70 * UNIT);
        assertEq(bond.slashAllowance(agent, enforcer), 20 * UNIT); // 50 - 30
    }

    function test_lock_revertsWithoutAllowance() public {
        _deposit(100 * UNIT);
        vm.prank(other); // never approved
        vm.expectRevert("ALLOWANCE");
        bond.lock(agent, creditor, 10 * UNIT, 0);
    }

    function test_lock_revertsOverFreeBond() public {
        _deposit(20 * UNIT);
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 100 * UNIT); // generous allowance...
        vm.prank(enforcer);
        vm.expectRevert("INSUFFICIENT_BOND"); // ...but only 20 bond exists
        bond.lock(agent, creditor, 50 * UNIT, 0);
    }

    function test_lockedBond_cannotBeWithdrawn() public {
        _deposit(100 * UNIT);
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 100 * UNIT);
        vm.prank(enforcer);
        bond.lock(agent, creditor, 80 * UNIT, 0);

        vm.prank(agent);
        vm.expectRevert("INSUFFICIENT_FREE");
        bond.withdraw(30 * UNIT); // only 20 free
    }

    // --- release (revolving) ---

    function test_release_restoresCapacity() public {
        _deposit(100 * UNIT);
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 50 * UNIT);
        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 30 * UNIT, 0);

        vm.prank(enforcer);
        bond.release(id);

        assertEq(bond.locked(agent), 0);
        assertEq(bond.freeBondOf(agent), 100 * UNIT);
        assertEq(bond.slashAllowance(agent, enforcer), 50 * UNIT); // restored
    }

    function test_release_onlyEnforcer() public {
        _deposit(100 * UNIT);
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 50 * UNIT);
        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 30 * UNIT, 0);

        vm.prank(other);
        vm.expectRevert("NOT_AUTHORIZED");
        bond.release(id);
    }

    function test_release_revertsOnNonActive() public {
        _deposit(100 * UNIT);
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 50 * UNIT);
        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 30 * UNIT, 0);
        vm.prank(enforcer);
        bond.release(id);

        vm.prank(enforcer);
        vm.expectRevert("NOT_ACTIVE");
        bond.release(id); // double release
    }

    // --- slash (default) ---

    function test_slash_paysCreditorAndBurnsCapacity() public {
        _deposit(100 * UNIT);
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 50 * UNIT);
        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 30 * UNIT, 0);

        vm.prank(enforcer);
        bond.slash(id);

        assertEq(usdc.balanceOf(creditor), 30 * UNIT);
        assertEq(bond.bond(agent), 70 * UNIT); // bond reduced
        assertEq(bond.locked(agent), 0);
        assertEq(bond.freeBondOf(agent), 70 * UNIT);
        assertEq(bond.slashAllowance(agent, enforcer), 20 * UNIT); // NOT restored
    }

    function test_slash_onlyEnforcer() public {
        _deposit(100 * UNIT);
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 50 * UNIT);
        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 30 * UNIT, 0);

        vm.prank(other);
        vm.expectRevert("NOT_ENFORCER");
        bond.slash(id);
    }

    function test_slash_revertsOnNonActive() public {
        _deposit(100 * UNIT);
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 50 * UNIT);
        vm.prank(enforcer);
        uint256 id = bond.lock(agent, creditor, 30 * UNIT, 0);
        vm.prank(enforcer);
        bond.slash(id);

        vm.prank(enforcer);
        vm.expectRevert("NOT_ACTIVE");
        bond.slash(id); // can't slash twice
    }

    // --- solvency: many agents/obligations never cross-drain ---

    function test_multipleObligations_isolated() public {
        _deposit(100 * UNIT);
        vm.startPrank(agent);
        bond.setSlashAllowance(enforcer, 100 * UNIT);
        vm.stopPrank();

        vm.prank(enforcer);
        uint256 id1 = bond.lock(agent, creditor, 30 * UNIT, 0);
        vm.prank(enforcer);
        uint256 id2 = bond.lock(agent, creditor, 40 * UNIT, 0);

        assertEq(bond.locked(agent), 70 * UNIT);

        vm.prank(enforcer);
        bond.slash(id1); // creditor gets 30
        vm.prank(enforcer);
        bond.release(id2); // 40 unlocked

        assertEq(usdc.balanceOf(creditor), 30 * UNIT);
        assertEq(bond.bond(agent), 70 * UNIT);
        assertEq(bond.locked(agent), 0);
        assertEq(bond.freeBondOf(agent), 70 * UNIT);
        // contract holds exactly the remaining bond
        assertEq(usdc.balanceOf(address(bond)), 70 * UNIT);
    }

    // --- allowance revocation ---

    function test_revokeAllowance_blocksNewLocks() public {
        _deposit(100 * UNIT);
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 50 * UNIT);
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 0); // revoke

        vm.prank(enforcer);
        vm.expectRevert("ALLOWANCE");
        bond.lock(agent, creditor, 10 * UNIT, 0);
    }

    // --- deadline / agent self-release (anti-griefing) ---

    function _lockWithDeadline(uint64 deadline) internal returns (uint256 id) {
        _deposit(100 * UNIT);
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 50 * UNIT);
        vm.prank(enforcer);
        id = bond.lock(agent, creditor, 30 * UNIT, deadline);
    }

    function test_agentSelfRelease_afterDeadline() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        uint256 id = _lockWithDeadline(deadline);

        vm.warp(deadline + 1);
        vm.prank(agent); // the enforcer abandoned it; the agent reclaims
        bond.release(id);

        assertEq(bond.locked(agent), 0);
        assertEq(bond.freeBondOf(agent), 100 * UNIT);
        assertEq(bond.slashAllowance(agent, enforcer), 50 * UNIT); // capacity revolves back
    }

    function test_agentSelfRelease_beforeDeadline_reverts() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        uint256 id = _lockWithDeadline(deadline);

        vm.warp(deadline - 1); // not yet expired
        vm.prank(agent);
        vm.expectRevert("NOT_AUTHORIZED");
        bond.release(id);
    }

    function test_agentSelfRelease_noDeadline_reverts() public {
        uint256 id = _lockWithDeadline(0); // 0 = no expiry
        vm.warp(block.timestamp + 3650 days); // even far in the future
        vm.prank(agent);
        vm.expectRevert("NOT_AUTHORIZED"); // agent can never self-release a no-deadline obligation
        bond.release(id);
    }

    function test_enforcerRelease_unaffectedByDeadline() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        uint256 id = _lockWithDeadline(deadline);

        vm.prank(enforcer); // enforcer can still resolve any time, before or after deadline
        bond.release(id);
        assertEq(bond.locked(agent), 0);
    }
}
