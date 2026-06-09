// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StreamPay, IERC20} from "../src/StreamPay.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev A token whose transfer() tries to reenter StreamPay.withdraw(). Proves the mutex + CEI:
///      the reentrant call must revert and there must be no double payout.
contract ReentrantToken {
    string public name = "Evil USDC";
    string public symbol = "eUSDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    StreamPay public target;
    uint256 public reentryId;
    bool public attempted;
    bool public reverted;

    function setTarget(StreamPay _t, uint256 _id) external {
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
        // On the way out to the recipient, try to reenter and withdraw again.
        if (address(target) != address(0) && !attempted) {
            attempted = true;
            try target.withdraw(reentryId, 0) {
                reverted = false;
            } catch {
                reverted = true;
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

/// @dev Token that skims 1% on every transfer — exercises balance-delta custody.
contract FeeToken {
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        _move(from, to, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "BALANCE");
        uint256 fee = amount / 100;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee; // 1% burned in transit
    }
}

contract StreamPayAdversarialTest is Test {
    StreamPay internal sp;

    address internal sender = address(0xA11CE);
    address internal recipient = address(0xB0B);

    function test_reentrancy_noDoublePay() public {
        ReentrantToken evil = new ReentrantToken();
        sp = new StreamPay(IERC20(address(evil)));

        uint64 start = uint64(block.timestamp);
        uint64 stop = start + 1000;

        evil.mint(sender, 1_000_000);
        vm.prank(sender);
        evil.approve(address(sp), 1_000_000);
        vm.prank(sender);
        uint256 id = sp.createStream(recipient, 1_000_000, start, stop, "evil");

        evil.setTarget(sp, id);
        vm.warp(start + 500); // 500k streamed

        vm.prank(recipient);
        sp.withdraw(id, 0); // triggers reentrancy attempt inside transfer()

        assertTrue(evil.attempted(), "reentry should have been attempted");
        assertTrue(evil.reverted(), "reentry must have reverted (mutex)");
        // Recipient got exactly the streamed amount once, not twice.
        assertEq(evil.balanceOf(recipient), 500_000);
        assertEq(evil.balanceOf(address(sp)), 500_000); // remainder still escrowed
    }

    function test_feeOnTransfer_escrowStaysSolvent() public {
        FeeToken fee = new FeeToken();
        sp = new StreamPay(IERC20(address(fee)));

        uint64 start = uint64(block.timestamp);
        uint64 stop = start + 1000;

        fee.mint(sender, 1_000_000);
        vm.prank(sender);
        fee.approve(address(sp), 1_000_000);
        vm.prank(sender);
        uint256 id = sp.createStream(recipient, 1_000_000, start, stop, "fee");

        // Only 990k actually arrived (1% skimmed) — the contract must escrow what it received.
        uint256 received = sp.get(id).deposit;
        assertEq(received, 990_000);
        assertEq(fee.balanceOf(address(sp)), 990_000);

        // Recipient withdraws everything at the end; contract never goes insolvent.
        vm.warp(stop);
        vm.prank(recipient);
        sp.withdraw(id, 0);
        assertEq(sp.get(id).deposit, 990_000);
        // Contract paid out exactly what it held (minus the fee on the way out).
        assertLe(fee.balanceOf(address(sp)), 0 + 1); // dust-free, no stranded surplus
    }

    function test_secondStream_cannotDrainFirst() public {
        MockERC20 usdc = new MockERC20();
        sp = new StreamPay(IERC20(address(usdc)));
        uint64 start = uint64(block.timestamp);
        uint64 stop = start + 1000;

        address s2 = address(0xC0FFEE);
        address r2 = address(0xDA7A);

        usdc.mint(sender, 1_000_000);
        usdc.mint(s2, 1_000_000);
        vm.prank(sender);
        usdc.approve(address(sp), 1_000_000);
        vm.prank(s2);
        usdc.approve(address(sp), 1_000_000);

        vm.prank(sender);
        uint256 id1 = sp.createStream(recipient, 1_000_000, start, stop, "one");
        vm.prank(s2);
        uint256 id2 = sp.createStream(r2, 1_000_000, start, stop, "two");

        vm.warp(stop);
        // r2 fully drains its own stream...
        vm.prank(r2);
        sp.withdraw(id2, 0);
        assertEq(usdc.balanceOf(r2), 1_000_000);
        // ...and stream 1's funds are untouched and fully claimable.
        assertEq(usdc.balanceOf(address(sp)), 1_000_000);
        vm.prank(recipient);
        sp.withdraw(id1, 0);
        assertEq(usdc.balanceOf(recipient), 1_000_000);
        assertEq(usdc.balanceOf(address(sp)), 0);
    }
}
