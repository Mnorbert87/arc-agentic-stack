// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CommitStake, IERC20} from "../src/CommitStake.sol";

/// @notice Deploys CommitStake to Arc testnet.
/// Run: forge script script/Deploy.s.sol --rpc-url arc_testnet --broadcast
/// Reads DEPLOYER_PRIVATE_KEY and ARC_USDC from the environment (.env).
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address usdc = vm.envAddress("ARC_USDC");

        vm.startBroadcast(pk);
        CommitStake cs = new CommitStake(IERC20(usdc));
        vm.stopBroadcast();

        console.log("CommitStake deployed at:", address(cs));
        console.log("USDC wired:", usdc);
    }
}
