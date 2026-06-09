// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentBond, IERC20} from "../src/AgentBond.sol";

/// @notice Deploys AgentBond to Arc testnet.
/// Run: forge script script/Deploy.s.sol --rpc-url arc_testnet --broadcast
/// Reads DEPLOYER_PRIVATE_KEY and ARC_USDC from the environment (.env).
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address usdc = vm.envAddress("ARC_USDC");

        vm.startBroadcast(pk);
        AgentBond ab = new AgentBond(IERC20(usdc));
        vm.stopBroadcast();

        console.log("AgentBond deployed at:", address(ab));
        console.log("USDC wired:", usdc);
    }
}
