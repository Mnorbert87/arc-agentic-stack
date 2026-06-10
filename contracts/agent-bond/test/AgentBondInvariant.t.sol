// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBond, IERC20} from "../src/AgentBond.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Drives AgentBond with random deposit/withdraw/grant/lock/release/slash/self-release
///      from several agents and enforcers, while keeping *ghost* accounting measured purely from
///      real ERC-20 balance movements (never from the contract's own bookkeeping). The invariants
///      then cross-check the contract's books against those independently observed token flows,
///      so a bookkeeping bug cannot hide by being self-consistent.
contract AgentBondHandler is Test {
    AgentBond public ab;
    MockERC20 public usdc;

    address[3] public agents = [address(0xA1), address(0xA2), address(0xA3)];
    address[2] public enforcers = [address(0xE1), address(0xE2)];
    // Creditors are disjoint from agents/enforcers so slashed funds visibly LEAVE the system.
    address[2] public creditors = [address(0xC1), address(0xC2)];
    uint256[] public openIds;

    // Ghost ledgers — updated ONLY from observed usdc.balanceOf deltas around each call.
    mapping(address => uint256) public ghostDeposited; // tokens that actually entered, per agent
    mapping(address => uint256) public ghostWithdrawn; // tokens that actually left to the agent
    mapping(address => uint256) public ghostSlashed; // tokens that actually left to a creditor, attributed to the agent

    constructor(AgentBond _ab, MockERC20 _usdc) {
        ab = _ab;
        usdc = _usdc;
        for (uint256 i; i < agents.length; i++) {
            usdc.mint(agents[i], 1_000_000e6);
            vm.prank(agents[i]);
            usdc.approve(address(ab), type(uint256).max);
        }
    }

    function deposit(uint256 ai, uint256 amt) public {
        address a = agents[ai % agents.length];
        amt = bound(amt, 1, 10_000e6);
        if (usdc.balanceOf(a) < amt) return;
        uint256 before = usdc.balanceOf(address(ab));
        vm.prank(a);
        ab.deposit(amt);
        ghostDeposited[a] += usdc.balanceOf(address(ab)) - before;
    }

    function withdraw(uint256 ai, uint256 amt) public {
        address a = agents[ai % agents.length];
        uint256 free = ab.bond(a) - ab.locked(a);
        if (free == 0) return;
        amt = bound(amt, 1, free);
        uint256 before = usdc.balanceOf(a);
        vm.prank(a);
        ab.withdraw(amt);
        ghostWithdrawn[a] += usdc.balanceOf(a) - before;
    }

    function grant(uint256 ai, uint256 ei, uint256 amt) public {
        address a = agents[ai % agents.length];
        address e = enforcers[ei % enforcers.length];
        amt = bound(amt, 0, 10_000e6);
        vm.prank(a);
        ab.setSlashAllowance(e, amt);
    }

    function lock(uint256 ai, uint256 ei, uint256 ci, uint256 amt, uint64 deadlineOffset) public {
        address a = agents[ai % agents.length];
        address e = enforcers[ei % enforcers.length];
        address c = creditors[ci % creditors.length];
        uint256 free = ab.bond(a) - ab.locked(a);
        uint256 allow = ab.slashAllowance(a, e);
        uint256 cap = free < allow ? free : allow;
        if (cap == 0) return;
        amt = bound(amt, 1, cap);
        // deadline: 0 (no expiry) or up to ~30 days out — exercises the self-release path too.
        uint64 deadline = deadlineOffset % 2 == 0
            ? 0
            : uint64(block.timestamp) + (deadlineOffset % 30 days) + 1;
        vm.prank(e);
        uint256 id = ab.lock(a, c, amt, deadline);
        openIds.push(id);
    }

    function release(uint256 idx) public {
        if (openIds.length == 0) return;
        uint256 id = openIds[idx % openIds.length];
        (, address e,,,, AgentBond.Status st) = ab.obligations(id);
        if (st != AgentBond.Status.Active) return;
        vm.prank(e);
        ab.release(id);
    }

    /// Agent reclaims an expired obligation itself (the anti-griefing path).
    function selfRelease(uint256 idx) public {
        if (openIds.length == 0) return;
        uint256 id = openIds[idx % openIds.length];
        (address a,,,, uint64 deadline, AgentBond.Status st) = ab.obligations(id);
        if (st != AgentBond.Status.Active || deadline == 0 || block.timestamp <= deadline) return;
        vm.prank(a);
        ab.release(id);
    }

    function slash(uint256 idx) public {
        if (openIds.length == 0) return;
        uint256 id = openIds[idx % openIds.length];
        (address a, address e, address c, uint256 amount,, AgentBond.Status st) = ab.obligations(id);
        if (st != AgentBond.Status.Active) return;
        uint256 before = usdc.balanceOf(c);
        vm.prank(e);
        ab.slash(id);
        // attribute by the creditor's real balance delta, not by the obligation's claimed amount
        ghostSlashed[a] += usdc.balanceOf(c) - before;
        amount; // silence unused warning; the delta is the source of truth
    }

    /// Time only moves forward (Arc timestamps are non-decreasing).
    function warp(uint256 delta) public {
        vm.warp(block.timestamp + bound(delta, 0, 7 days));
    }

    // --- aggregation views for the invariants ---

    function agentCount() external view returns (uint256) {
        return agents.length;
    }

    function sumBonds() external view returns (uint256 s) {
        for (uint256 i; i < agents.length; i++) s += ab.bond(agents[i]);
    }

    function sumNetGhostFlow() external view returns (uint256 s) {
        for (uint256 i; i < agents.length; i++) {
            address a = agents[i];
            s += ghostDeposited[a] - ghostWithdrawn[a] - ghostSlashed[a];
        }
    }
}

contract AgentBondInvariantTest is Test {
    AgentBond ab;
    MockERC20 usdc;
    AgentBondHandler h;

    function setUp() public {
        usdc = new MockERC20();
        ab = new AgentBond(IERC20(address(usdc)));
        h = new AgentBondHandler(ab, usdc);
        targetContract(address(h));
    }

    /// SOLVENCY (book vs reality): the contract's actual token balance equals the sum of every
    /// agent's recorded bond. The contract can never owe more than it physically holds.
    function invariant_solvent_bookMatchesBalance() public view {
        assertEq(usdc.balanceOf(address(ab)), h.sumBonds(), "INSOLVENT: balance != sum(bonds)");
    }

    /// SOLVENCY (pure flow): the actual token balance also equals what we independently watched
    /// flow in minus what we watched flow out (withdrawals + slashes). Nothing is ever paid out
    /// that was not first paid in.
    function invariant_solvent_flowConservation() public view {
        assertEq(
            usdc.balanceOf(address(ab)),
            h.sumNetGhostFlow(),
            "FLOW LEAK: balance != deposits - withdrawals - slashes"
        );
    }

    /// BOND EQUATION: for every agent, free + locked == deposits - slashed - withdrawn, where the
    /// right side comes from the ghost ledger (observed token movements) and the left side from
    /// the contract's books. A drifting `bond`/`locked` mapping fails this immediately.
    function invariant_bondEquation() public view {
        for (uint256 i; i < h.agentCount(); i++) {
            address a = h.agents(i);
            uint256 free = ab.bond(a) - ab.locked(a);
            assertEq(
                free + ab.locked(a),
                h.ghostDeposited(a) - h.ghostSlashed(a) - h.ghostWithdrawn(a),
                "BOND EQUATION violated"
            );
        }
    }

    /// An agent's locked amount can never exceed its total bond (otherwise free underflows /
    /// the agent is over-committed).
    function invariant_lockedNeverExceedsBond() public view {
        for (uint256 i; i < h.agentCount(); i++) {
            address a = h.agents(i);
            assertLe(ab.locked(a), ab.bond(a), "locked > bond for some agent");
        }
    }
}
