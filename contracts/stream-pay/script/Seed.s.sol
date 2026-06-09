// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {StreamPay} from "../src/StreamPay.sol";

interface IApprove { function approve(address, uint256) external returns (bool); }

/// @notice Seeds demo streams into a freshly deployed StreamPay. Reads SP_ADDR, ARC_USDC,
///         DEPLOYER_PRIVATE_KEY from env. Three live streams with different windows so the UI
///         balance ticks visibly.
contract Seed is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        StreamPay sp = StreamPay(vm.envAddress("SP_ADDR"));
        address usdc = vm.envAddress("ARC_USDC");
        uint256 U = 1e6;
        uint64 t = uint64(block.timestamp);

        vm.startBroadcast(pk);
        IApprove(usdc).approve(address(sp), type(uint256).max);
        sp.createStream(me, 8 * U, t,          t + 3600,  "agent salary - 1h");
        sp.createStream(me, 7 * U, t - 1800,    t + 1800,  "pay-per-inference (~50pct streamed)");
        sp.createStream(me, 5 * U, t,           t + 86400, "API subscription - 24h");
        vm.stopBroadcast();

        console.log("StreamPay seeded:", address(sp));
    }
}
