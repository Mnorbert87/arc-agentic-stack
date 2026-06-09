// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentBond, IERC20} from "../src/AgentBond.sol";

interface IApprove { function approve(address, uint256) external returns (bool); }

/// @notice Seeds demo data into a freshly deployed AgentBond. Reads AB_ADDR, ARC_USDC,
///         DEPLOYER_PRIVATE_KEY from env. Creates 3 obligations: one Active (with a deadline,
///         to showcase agent self-release), one Released, one Slashed — so the UI shows all states.
contract Seed is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        AgentBond ab = AgentBond(vm.envAddress("AB_ADDR"));
        address usdc = vm.envAddress("ARC_USDC");
        uint256 U = 1e6;

        vm.startBroadcast(pk);
        IApprove(usdc).approve(address(ab), type(uint256).max);
        ab.deposit(25 * U);
        ab.setSlashAllowance(me, 25 * U);

        uint256 id1 = ab.lock(me, me, 10 * U, uint64(block.timestamp + 30 days)); // Active + deadline
        uint256 id2 = ab.lock(me, me, 8 * U, 0);
        ab.release(id2); // Released
        uint256 id3 = ab.lock(me, me, 5 * U, 0);
        ab.slash(id3); // Slashed
        vm.stopBroadcast();

        console.log("AgentBond seeded:", address(ab));
        console.log("obligations (active/released/slashed):", id1, id2, id3);
    }
}
