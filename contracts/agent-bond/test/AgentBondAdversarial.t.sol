// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBond, IERC20} from "../src/AgentBond.sol";

/// @dev A USDC-like token whose transfer() reenters AgentBond on the way out. Proves the mutex +
///      checks-effects-interactions ordering hold: the reentrant call must revert and there must
///      be no double payout / no bond accounting corruption.
contract ReentrantToken {
    string public name = "Evil USDC";
    string public symbol = "eUSDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    AgentBond public target;
    uint256 public reentryId;
    bool public reentryAttempted;
    bool public reentryReverted;

    function setTarget(AgentBond _t, uint256 _id) external {
        target = _t;
        reentryId = _id;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ALLOWANCE");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        // On the way OUT of the bond, try to reenter and slash/withdraw again.
        if (address(target) != address(0) && !reentryAttempted) {
            reentryAttempted = true;
            try target.slash(reentryId) {
                // reentry succeeded -> contract is broken
            } catch {
                reentryReverted = true;
            }
        }
        _transfer(msg.sender, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract AgentBondAdversarialTest is Test {
    AgentBond bond;
    ReentrantToken evil;

    address agent = address(0xA1);
    address enforcer = address(0xE1);

    uint256 constant UNIT = 1e6;

    function setUp() public {
        evil = new ReentrantToken();
        bond = new AgentBond(IERC20(address(evil)));

        evil.mint(agent, 1000 * UNIT);
        vm.prank(agent);
        evil.approve(address(bond), type(uint256).max);

        vm.prank(agent);
        bond.deposit(100 * UNIT);
        vm.prank(agent);
        bond.setSlashAllowance(enforcer, 100 * UNIT);
    }

    /// @notice A reentrant slash during the creditor payout must fail; the bond pays out exactly once.
    function test_reentrantSlash_blocked() public {
        // creditor is the evil token contract so its transfer hook fires inside slash()
        vm.prank(enforcer);
        uint256 id = bond.lock(agent, address(evil), 30 * UNIT, 0);
        evil.setTarget(bond, id);

        vm.prank(enforcer);
        bond.slash(id);

        assertTrue(evil.reentryAttempted(), "reentry path not exercised");
        assertTrue(evil.reentryReverted(), "reentrancy was NOT blocked");

        // exactly one payout of 30 to the creditor; bond reduced by exactly 30
        assertEq(evil.balanceOf(address(evil)), 30 * UNIT);
        assertEq(bond.bond(agent), 70 * UNIT);
        assertEq(bond.locked(agent), 0);
        // contract still solvent: holds the remaining 70 bond
        assertEq(evil.balanceOf(address(bond)), 70 * UNIT);
    }
}
