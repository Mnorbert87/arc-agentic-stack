// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StreamPay, IERC20} from "../src/StreamPay.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Regression: views must reflect terminal state, never report phantom withdrawable funds.
contract TerminalViewTest is Test {
    StreamPay sp;
    MockERC20 usdc;
    address sender = address(0xA11CE);
    address recipient = address(0xB0B);

    function setUp() public {
        usdc = new MockERC20();
        sp = new StreamPay(IERC20(address(usdc)));
        usdc.mint(sender, 1_000e6);
        vm.prank(sender);
        usdc.approve(address(sp), type(uint256).max);
    }

    function test_views_zeroAfterCancel() public {
        uint64 start = uint64(block.timestamp);
        uint64 stop = start + 100;
        vm.prank(sender);
        uint256 id = sp.createStream(recipient, 100e6, start, stop, "x");
        vm.warp(start + 50);
        vm.prank(sender);
        sp.cancel(id);
        vm.warp(start + 90);
        assertEq(sp.recipientBalance(id), 0, "recipientBalance must be 0 on cancelled stream");
        assertEq(sp.senderBalance(id), 0, "senderBalance must be 0 on cancelled stream");
        // and withdraw indeed reverts (no funds actually retrievable)
        vm.prank(recipient);
        vm.expectRevert(bytes("NOT_ACTIVE"));
        sp.withdraw(id, 0);
    }

    function test_views_zeroAfterFullWithdraw() public {
        uint64 start = uint64(block.timestamp);
        uint64 stop = start + 100;
        vm.prank(sender);
        uint256 id = sp.createStream(recipient, 100e6, start, stop, "x");
        vm.warp(stop + 1);
        vm.prank(recipient);
        sp.withdraw(id, 0); // full
        assertEq(sp.recipientBalance(id), 0);
        assertEq(sp.senderBalance(id), 0);
    }
}
