// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Script} from "forge-std/Script.sol";
import {PaymentSplitter} from "../lib/octant-v2-core/src/core/PaymentSplitter.sol";
import {DataCommonsDAO} from "../src/dataCommonsDAO.sol";
import {YieldDonatingTokenizedStrategy} from "../lib/octant-v2-core/src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import {YieldDonating} from "../src/yieldDonating.sol";

contract DeployContracts is Script {
    address public constant AAVE_V3_POOL =
        0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant USDC_ADDRESS =
        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function run() external {
        vm.startBroadcast();
        PaymentSplitter splitter = new PaymentSplitter();
        DataCommonsDAO dao = new DataCommonsDAO(
            block.timestamp + 1 days,
            block.timestamp + 8 days,
            block.timestamp + 15 days,
            8,
            0,
            address(splitter)
        );
        YieldDonatingTokenizedStrategy tokenizedStrategy = new YieldDonatingTokenizedStrategy();
        YieldDonating strategy = new YieldDonating(
            AAVE_V3_POOL,
            USDC_ADDRESS,
            "DataCommons",
            msg.sender,
            msg.sender,
            msg.sender,
            address(splitter),
            true,
            address(tokenizedStrategy)
        );
        vm.stopBroadcast();
    }
}
