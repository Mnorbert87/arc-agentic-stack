// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StreamPay, IERC20} from "../src/StreamPay.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Property-based unit tests over the whole parameter space. Expected values are computed
///      in the test from first principles (linear vesting spec) and checked against REAL token
///      balance movements.
contract StreamPayFuzzTest is Test {
    StreamPay sp;
    MockERC20 usdc;

    address sender = address(0x51);
    address recipient = address(0xB1);

    uint256 constant MAX_DEPOSIT = 1_000_000_000e6;

    function setUp() public {
        usdc = new MockERC20();
        sp = new StreamPay(IERC20(address(usdc)));
        usdc.mint(sender, MAX_DEPOSIT);
        vm.prank(sender);
        usdc.approve(address(sp), type(uint256).max);
        vm.warp(1_000_000); // realistic, non-zero starting time
    }

    /// The spec: linear vesting, floored. Computed independently of the contract.
    function expectedVested(uint256 deposit, uint256 start, uint256 stop, uint256 t)
        internal
        pure
        returns (uint256)
    {
        if (t <= start) return 0;
        if (t >= stop) return deposit;
        return (deposit * (t - start)) / (stop - start);
    }

    /// At any point in a stream's life, a full withdraw pays the recipient exactly the spec's
    /// vested amount, and one token more is never withdrawable.
    function testFuzz_withdrawPaysExactlyVested(uint256 deposit, uint64 duration, uint64 elapsed)
        public
    {
        deposit = bound(deposit, 1, MAX_DEPOSIT);
        duration = uint64(bound(duration, 1, 365 days));
        elapsed = uint64(bound(elapsed, 0, duration * 2));

        uint64 start = uint64(block.timestamp);
        uint64 stop = start + duration;
        vm.prank(sender);
        uint256 id = sp.createStream(recipient, deposit, start, stop, "fuzz");

        vm.warp(start + elapsed);
        uint256 vested = expectedVested(deposit, start, stop, block.timestamp);

        if (vested == 0) {
            vm.prank(recipient);
            vm.expectRevert(bytes("NOTHING_TO_WITHDRAW"));
            sp.withdraw(id, 0);
            return;
        }

        // one unit above the vested amount must never be withdrawable
        if (vested < deposit) {
            vm.prank(recipient);
            vm.expectRevert(bytes("EXCEEDS_AVAILABLE"));
            sp.withdraw(id, vested + 1);
        }

        uint256 before = usdc.balanceOf(recipient);
        vm.prank(recipient);
        sp.withdraw(id, 0); // 0 = withdraw everything available
        assertEq(usdc.balanceOf(recipient) - before, vested, "payout != spec vested amount");
    }

    /// Cancel at any time splits the deposit exactly: recipient gets the vested part (minus what
    /// it already took), sender gets the rest, nothing remains in escrow for the stream.
    function testFuzz_cancelSplitsExactly(
        uint256 deposit,
        uint64 duration,
        uint64 elapsed,
        uint256 preWithdraw
    ) public {
        deposit = bound(deposit, 1, MAX_DEPOSIT);
        duration = uint64(bound(duration, 1, 365 days));
        elapsed = uint64(bound(elapsed, 0, duration * 2));

        uint64 start = uint64(block.timestamp);
        uint64 stop = start + duration;
        vm.prank(sender);
        uint256 id = sp.createStream(recipient, deposit, start, stop, "fuzz");

        vm.warp(start + elapsed);
        uint256 vested = expectedVested(deposit, start, stop, block.timestamp);

        // recipient may have taken some of its vested funds before the cancel
        uint256 taken;
        if (vested > 0) {
            taken = bound(preWithdraw, 0, vested);
            if (taken > 0) {
                vm.prank(recipient);
                sp.withdraw(id, taken);
            }
        }
        if (taken == deposit) return; // fully streamed and withdrawn -> stream already terminal

        uint256 recBefore = usdc.balanceOf(recipient);
        uint256 senBefore = usdc.balanceOf(sender);
        vm.prank(sender);
        sp.cancel(id);

        assertEq(usdc.balanceOf(recipient) - recBefore, vested - taken, "recipient split wrong");
        assertEq(usdc.balanceOf(sender) - senBefore, deposit - vested, "sender refund wrong");
        // total recipient payout + sender refund == deposit, to the token
        assertEq(
            (usdc.balanceOf(recipient) - recBefore) + taken + (usdc.balanceOf(sender) - senBefore),
            deposit,
            "cancel lost or minted funds"
        );
    }

    /// Vesting is monotone: at a later time the vested amount never decreases.
    function testFuzz_vestingIsMonotone(uint256 deposit, uint64 duration, uint64 t1, uint64 t2)
        public
    {
        deposit = bound(deposit, 1, MAX_DEPOSIT);
        duration = uint64(bound(duration, 1, 365 days));
        t1 = uint64(bound(t1, 0, duration * 2));
        t2 = uint64(bound(t2, t1, duration * 2));

        uint64 start = uint64(block.timestamp);
        vm.prank(sender);
        uint256 id = sp.createStream(recipient, deposit, start, start + duration, "fuzz");

        vm.warp(start + t1);
        uint256 v1 = sp.streamedTotal(id);
        vm.warp(start + t2);
        uint256 v2 = sp.streamedTotal(id);
        assertLe(v1, v2, "vesting went backwards");
        assertLe(v2, deposit, "vested more than the deposit");
    }

    /// ACCESS FUZZ: a random address that is neither party can neither withdraw nor cancel.
    function testFuzz_stranger_cannotTouchStream(address rando, uint256 deposit) public {
        deposit = bound(deposit, 1, MAX_DEPOSIT);
        vm.assume(rando != sender && rando != recipient);

        uint64 start = uint64(block.timestamp);
        vm.prank(sender);
        uint256 id = sp.createStream(recipient, deposit, start, start + 1000, "fuzz");
        vm.warp(start + 500);

        vm.prank(rando);
        vm.expectRevert(bytes("NOT_RECIPIENT"));
        sp.withdraw(id, 0);

        vm.prank(rando);
        vm.expectRevert(bytes("NOT_PARTY"));
        sp.cancel(id);
    }
}
