// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StreamPay, IERC20} from "../src/StreamPay.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract StreamPayTest is Test {
    StreamPay internal sp;
    MockERC20 internal usdc;

    address internal sender = address(0xA11CE);
    address internal recipient = address(0xB0B);

    uint64 internal start;
    uint64 internal stop;
    uint256 internal constant DEPOSIT = 1_000_000; // 1 USDC (6 decimals)

    function setUp() public {
        usdc = new MockERC20();
        sp = new StreamPay(IERC20(address(usdc)));
        start = uint64(block.timestamp);
        stop = start + 1000; // 1000-second stream

        usdc.mint(sender, DEPOSIT);
        vm.prank(sender);
        usdc.approve(address(sp), DEPOSIT);
    }

    function _open() internal returns (uint256 id) {
        vm.prank(sender);
        id = sp.createStream(recipient, DEPOSIT, start, stop, "agent salary");
    }

    function test_create_pullsFundsAndRecords() public {
        uint256 id = _open();
        assertEq(usdc.balanceOf(address(sp)), DEPOSIT);
        assertEq(usdc.balanceOf(sender), 0);

        StreamPay.Stream memory s = sp.get(id);
        assertEq(s.sender, sender);
        assertEq(s.recipient, recipient);
        assertEq(s.deposit, DEPOSIT);
        assertEq(s.withdrawn, 0);
        assertEq(uint256(s.status), 1); // Active
    }

    function test_accrual_isLinear() public {
        uint256 id = _open();
        assertEq(sp.streamedTotal(id), 0);

        vm.warp(start + 250);
        assertEq(sp.streamedTotal(id), DEPOSIT / 4);
        assertEq(sp.recipientBalance(id), DEPOSIT / 4);
        assertEq(sp.senderBalance(id), DEPOSIT - DEPOSIT / 4);

        vm.warp(start + 1000);
        assertEq(sp.streamedTotal(id), DEPOSIT);
        assertEq(sp.senderBalance(id), 0);

        // After stop, still capped at deposit.
        vm.warp(start + 5000);
        assertEq(sp.streamedTotal(id), DEPOSIT);
    }

    function test_withdraw_partialThenFull() public {
        uint256 id = _open();
        vm.warp(start + 500);

        vm.prank(recipient);
        sp.withdraw(id, 200_000);
        assertEq(usdc.balanceOf(recipient), 200_000);
        assertEq(sp.recipientBalance(id), 300_000); // 500k streamed - 200k taken

        // Withdraw remaining available with amount=0 sentinel.
        vm.prank(recipient);
        sp.withdraw(id, 0);
        assertEq(usdc.balanceOf(recipient), 500_000);
        assertEq(sp.recipientBalance(id), 0);

        // Finish the stream and withdraw the rest.
        vm.warp(stop);
        vm.prank(recipient);
        sp.withdraw(id, 0);
        assertEq(usdc.balanceOf(recipient), DEPOSIT);

        StreamPay.Stream memory s = sp.get(id);
        assertEq(uint256(s.status), 2); // Ended
        assertEq(usdc.balanceOf(address(sp)), 0);
    }

    function test_cancel_splitsCorrectly() public {
        uint256 id = _open();
        vm.warp(start + 400);

        // Recipient already took some.
        vm.prank(recipient);
        sp.withdraw(id, 100_000);

        vm.prank(sender);
        sp.cancel(id);

        // 400k streamed: recipient gets 400k total (100k earlier + 300k now), sender gets 600k.
        assertEq(usdc.balanceOf(recipient), 400_000);
        assertEq(usdc.balanceOf(sender), 600_000);
        assertEq(usdc.balanceOf(address(sp)), 0);

        StreamPay.Stream memory s = sp.get(id);
        assertEq(uint256(s.status), 2); // Ended
    }

    function test_cancel_byRecipient_allowed() public {
        uint256 id = _open();
        vm.warp(start + 100);
        vm.prank(recipient);
        sp.cancel(id);
        assertEq(usdc.balanceOf(recipient), 100_000);
        assertEq(usdc.balanceOf(sender), 900_000);
    }

    function test_cancel_beforeStart_refundsSenderFully() public {
        start = uint64(block.timestamp + 1000);
        stop = start + 1000;
        vm.prank(sender);
        usdc.approve(address(sp), DEPOSIT);
        vm.prank(sender);
        uint256 id = sp.createStream(recipient, DEPOSIT, start, stop, "future");

        vm.prank(sender);
        sp.cancel(id);
        assertEq(usdc.balanceOf(sender), DEPOSIT);
        assertEq(usdc.balanceOf(recipient), 0);
    }

    // --- access control / guards ---

    function test_withdraw_onlyRecipient() public {
        uint256 id = _open();
        vm.warp(start + 500);
        vm.expectRevert("NOT_RECIPIENT");
        vm.prank(sender);
        sp.withdraw(id, 1);
    }

    function test_withdraw_cannotExceedStreamed() public {
        uint256 id = _open();
        vm.warp(start + 100); // only 100k streamed
        vm.expectRevert("EXCEEDS_AVAILABLE");
        vm.prank(recipient);
        sp.withdraw(id, 200_000);
    }

    function test_cancel_onlyParties() public {
        uint256 id = _open();
        vm.expectRevert("NOT_PARTY");
        vm.prank(address(0xDEAD));
        sp.cancel(id);
    }

    function test_cancel_twice_reverts() public {
        uint256 id = _open();
        vm.warp(start + 100);
        vm.prank(sender);
        sp.cancel(id);
        vm.expectRevert("NOT_ACTIVE");
        vm.prank(sender);
        sp.cancel(id);
    }

    function test_create_badWindow_reverts() public {
        vm.prank(sender);
        usdc.approve(address(sp), DEPOSIT);
        vm.expectRevert("BAD_WINDOW");
        vm.prank(sender);
        sp.createStream(recipient, DEPOSIT, stop, start, "bad");
    }

    function test_create_zeroDeposit_reverts() public {
        vm.expectRevert("DEPOSIT_ZERO");
        vm.prank(sender);
        sp.createStream(recipient, 0, start, stop, "zero");
    }

    // --- solvency: floor accrual + remainder split never over/under-pays ---

    function testFuzz_solventSplit(uint256 deposit, uint64 t) public {
        // Fresh parties so the setUp() balances don't pollute the end-state sum check.
        address fSender = address(0x5E11DE5);
        address fRecipient = address(0x5EC1B0B);
        deposit = bound(deposit, 1, 1e24);
        uint64 s0 = uint64(block.timestamp);
        uint64 s1 = s0 + 1000;
        usdc.mint(fSender, deposit);
        vm.prank(fSender);
        usdc.approve(address(sp), deposit);
        vm.prank(fSender);
        uint256 id = sp.createStream(fRecipient, deposit, s0, s1, "fuzz");

        t = uint64(bound(t, s0, s0 + 2000));
        vm.warp(t);

        uint256 streamed = sp.streamedTotal(id);
        assertLe(streamed, deposit, "streamed never exceeds deposit");
        assertEq(sp.recipientBalance(id) + sp.senderBalance(id), deposit, "split sums to deposit");

        vm.prank(fSender);
        sp.cancel(id);
        // Everything left the contract; nothing stranded, nothing conjured.
        assertEq(usdc.balanceOf(fRecipient) + usdc.balanceOf(fSender), deposit);
        assertEq(usdc.balanceOf(address(sp)), 0);
    }
}
