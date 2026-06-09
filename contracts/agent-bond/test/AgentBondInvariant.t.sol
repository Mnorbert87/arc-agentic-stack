// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBond, IERC20} from "../src/AgentBond.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Drives AgentBond with random deposit/withdraw/grant/lock/release/slash from several
///      agents and enforcers, then asserts global solvency: the contract's USDC balance always
///      equals the sum of every agent's recorded bond, and free+locked accounting never diverges.
contract AgentBondHandler is Test {
    AgentBond public ab;
    MockERC20 public usdc;

    address[3] public agents = [address(0xA1), address(0xA2), address(0xA3)];
    address[2] public enforcers = [address(0xE1), address(0xE2)];
    uint256[] public openIds;

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
        vm.prank(a);
        ab.deposit(amt);
    }

    function withdraw(uint256 ai, uint256 amt) public {
        address a = agents[ai % agents.length];
        uint256 free = ab.bond(a) - ab.locked(a);
        if (free == 0) return;
        amt = bound(amt, 1, free);
        vm.prank(a);
        ab.withdraw(amt);
    }

    function grant(uint256 ai, uint256 ei, uint256 amt) public {
        address a = agents[ai % agents.length];
        address e = enforcers[ei % enforcers.length];
        amt = bound(amt, 0, 10_000e6);
        vm.prank(a);
        ab.setSlashAllowance(e, amt);
    }

    function lock(uint256 ai, uint256 ei, uint256 amt) public {
        address a = agents[ai % agents.length];
        address e = enforcers[ei % enforcers.length];
        uint256 free = ab.bond(a) - ab.locked(a);
        uint256 allow = ab.slashAllowance(a, e);
        uint256 cap = free < allow ? free : allow;
        if (cap == 0) return;
        amt = bound(amt, 1, cap);
        vm.prank(e);
        uint256 id = ab.lock(a, e, amt, 0); // creditor = enforcer for the test
        openIds.push(id);
    }

    function release(uint256 idx) public {
        if (openIds.length == 0) return;
        uint256 id = openIds[idx % openIds.length];
        (,address e,,,,AgentBond.Status st) = ab.obligations(id);
        if (st != AgentBond.Status.Active) return;
        vm.prank(e);
        ab.release(id);
    }

    function slash(uint256 idx) public {
        if (openIds.length == 0) return;
        uint256 id = openIds[idx % openIds.length];
        (,address e,,,,AgentBond.Status st) = ab.obligations(id);
        if (st != AgentBond.Status.Active) return;
        vm.prank(e);
        ab.slash(id);
    }

    function sumBonds() external view returns (uint256 s) {
        for (uint256 i; i < agents.length; i++) s += ab.bond(agents[i]);
    }

    function sumLockedLeFree() external view returns (bool) {
        for (uint256 i; i < agents.length; i++) {
            if (ab.locked(agents[i]) > ab.bond(agents[i])) return false;
        }
        return true;
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

    /// Contract custody == sum of recorded bonds. Slashed funds leave to creditors (also agents?
    /// no — creditor=enforcer here, an external address), so balance tracks bonds exactly.
    function invariant_solvent() public view {
        assertEq(usdc.balanceOf(address(ab)), h.sumBonds(), "INSOLVENT: balance != sum(bonds)");
    }

    function invariant_lockedNeverExceedsBond() public view {
        assertTrue(h.sumLockedLeFree(), "locked > bond for some agent");
    }
}
