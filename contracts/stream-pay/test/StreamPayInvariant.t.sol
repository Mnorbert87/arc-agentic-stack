// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StreamPay, IERC20} from "../src/StreamPay.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Drives StreamPay with random create/withdraw/cancel/warp across several senders and
///      recipients. All ghost accounting is measured from REAL ERC-20 balance deltas, and the
///      vesting cap is recomputed in the test from the stream's immutable parameters — never by
///      asking the contract — so the invariants check the implementation against the spec, not
///      against itself.
contract StreamPayHandler is Test {
    StreamPay public sp;
    MockERC20 public usdc;

    address[2] public senders = [address(0x51), address(0x52)];
    address[2] public recipients = [address(0xB1), address(0xB2)];

    struct Ghost {
        address sender;
        address recipient;
        uint256 depositIn; // tokens that actually entered escrow at create
        uint256 recipientPaid; // tokens that actually reached the recipient
        uint256 senderRefunded; // tokens that actually went back to the sender
        uint64 start;
        uint64 stop;
    }

    uint256[] public ids;
    mapping(uint256 => Ghost) public ghosts;

    constructor(StreamPay _sp, MockERC20 _usdc) {
        sp = _sp;
        usdc = _usdc;
        for (uint256 i; i < senders.length; i++) {
            usdc.mint(senders[i], 1_000_000_000e6);
            vm.prank(senders[i]);
            usdc.approve(address(sp), type(uint256).max);
        }
    }

    function createStream(uint256 si, uint256 ri, uint256 amt, uint64 startOffset, uint64 duration)
        public
    {
        address s = senders[si % senders.length];
        address r = recipients[ri % recipients.length];
        amt = bound(amt, 1, 1_000_000e6);
        if (usdc.balanceOf(s) < amt) return;
        // start may be slightly in the past or in the future; stop must be > now
        uint64 start = uint64(block.timestamp) + (startOffset % 7 days);
        if (startOffset % 3 == 0 && block.timestamp > 1 days) {
            start = uint64(block.timestamp - (startOffset % 1 days));
        }
        uint64 stop = start + (duration % 30 days) + 1;
        if (stop <= block.timestamp) return;

        uint256 escrowBefore = usdc.balanceOf(address(sp));
        vm.prank(s);
        uint256 id = sp.createStream(r, amt, start, stop, "inv");
        ids.push(id);
        ghosts[id] = Ghost({
            sender: s,
            recipient: r,
            depositIn: usdc.balanceOf(address(sp)) - escrowBefore,
            recipientPaid: 0,
            senderRefunded: 0,
            start: start,
            stop: stop
        });
    }

    function withdraw(uint256 idx, uint256 amt) public {
        if (ids.length == 0) return;
        uint256 id = ids[idx % ids.length];
        Ghost storage g = ghosts[id];
        uint256 available = sp.recipientBalance(id);
        if (available == 0) return;
        amt = bound(amt, 1, available);
        uint256 before = usdc.balanceOf(g.recipient);
        vm.prank(g.recipient);
        sp.withdraw(id, amt);
        g.recipientPaid += usdc.balanceOf(g.recipient) - before;
    }

    function cancel(uint256 idx, bool byRecipient) public {
        if (ids.length == 0) return;
        uint256 id = ids[idx % ids.length];
        Ghost storage g = ghosts[id];
        StreamPay.Stream memory s = sp.get(id);
        if (s.status != StreamPay.Status.Active) return;
        uint256 recBefore = usdc.balanceOf(g.recipient);
        uint256 senBefore = usdc.balanceOf(g.sender);
        vm.prank(byRecipient ? g.recipient : g.sender);
        sp.cancel(id);
        g.recipientPaid += usdc.balanceOf(g.recipient) - recBefore;
        g.senderRefunded += usdc.balanceOf(g.sender) - senBefore;
    }

    /// Time only moves forward (Arc timestamps are non-decreasing).
    function warp(uint256 delta) public {
        vm.warp(block.timestamp + bound(delta, 0, 3 days));
    }

    // --- aggregation for the invariants ---

    function count() external view returns (uint256) {
        return ids.length;
    }

    function sumEscrowOwed() external view returns (uint256 s) {
        for (uint256 i; i < ids.length; i++) {
            Ghost storage g = ghosts[ids[i]];
            s += g.depositIn - g.recipientPaid - g.senderRefunded;
        }
    }

    /// The spec's linear vesting cap at the CURRENT timestamp, computed from immutable stream
    /// parameters only. Vesting is monotone in time, so every past payout is bounded by this.
    function vestedCapNow(uint256 id) public view returns (uint256) {
        Ghost storage g = ghosts[id];
        if (block.timestamp <= g.start) return 0;
        if (block.timestamp >= g.stop) return g.depositIn;
        return (g.depositIn * (block.timestamp - g.start)) / (uint256(g.stop) - g.start);
    }
}

contract StreamPayInvariantTest is Test {
    StreamPay sp;
    MockERC20 usdc;
    StreamPayHandler h;

    function setUp() public {
        usdc = new MockERC20();
        sp = new StreamPay(IERC20(address(usdc)));
        h = new StreamPayHandler(sp, usdc);
        targetContract(address(h));
    }

    /// SOLVENCY (pure flow): the escrow's real token balance always equals deposits-in minus
    /// payouts-out, summed over every stream. No stream can ever be paid from another's funds
    /// and the contract can never pay out more than was paid in.
    function invariant_solvent_flowConservation() public view {
        assertEq(
            usdc.balanceOf(address(sp)),
            h.sumEscrowOwed(),
            "FLOW LEAK: escrow balance != sum(deposit - paid out)"
        );
    }

    /// VESTING BOUND: the recipient's cumulative real payout never exceeds the linear vesting
    /// cap recomputed from the stream's parameters (start/stop/deposit) at the current time.
    function invariant_withdrawNeverExceedsVested() public view {
        for (uint256 i; i < h.count(); i++) {
            uint256 id = h.ids(i);
            (,,, uint256 recipientPaid,,,) = h.ghosts(id);
            assertLe(recipientPaid, h.vestedCapNow(id), "recipient paid more than vested");
        }
    }

    /// PER-STREAM CONSERVATION: recipient payout + sender refund never exceeds what entered
    /// escrow for that stream; on a terminal stream the two sides sum to exactly the deposit.
    function invariant_perStreamConservation() public view {
        for (uint256 i; i < h.count(); i++) {
            uint256 id = h.ids(i);
            (,, uint256 depositIn, uint256 recipientPaid, uint256 senderRefunded,,) = h.ghosts(id);
            assertLe(recipientPaid + senderRefunded, depositIn, "stream paid out more than deposit");
            if (sp.get(id).status == StreamPay.Status.Ended) {
                assertEq(
                    recipientPaid + senderRefunded, depositIn, "terminal stream lost or minted funds"
                );
            }
        }
    }
}
