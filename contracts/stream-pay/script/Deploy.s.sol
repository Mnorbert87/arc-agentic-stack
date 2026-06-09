// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {StreamPay, IERC20} from "../src/StreamPay.sol";

/// @notice Deploys StreamPay to Arc testnet.
/// Run: forge script script/Deploy.s.sol --rpc-url arc_testnet --broadcast
/// Reads DEPLOYER_PRIVATE_KEY and ARC_USDC from the environment (.env).
/// Arc testnet USDC: 0x3600000000000000000000000000000000000000
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address usdc = vm.envAddress("ARC_USDC");

        vm.startBroadcast(pk);
        StreamPay sp = new StreamPay(IERC20(usdc));
        vm.stopBroadcast();

        console.log("StreamPay deployed at:", address(sp));
        console.log("USDC wired:", usdc);
    }
}
