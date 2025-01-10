// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {ScEngine} from "../src/ScEngine.sol";
import {Stablecoin} from "../src/Stablecoin.sol";

contract ScEngineScript is Script {
    address[] public tokens;
    address[] public priceFeeds;

    function run() public returns (Stablecoin, ScEngine, HelperConfig) {
        HelperConfig config = new HelperConfig();

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            config.activeNetworkConfig();

        tokens = [weth, wbtc];
        priceFeeds = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey);

        Stablecoin sc = new Stablecoin();
        ScEngine scEngine = new ScEngine(tokens, priceFeeds, address(sc));
        sc.transferOwnership(address(scEngine));

        vm.stopBroadcast();

        return (sc, scEngine, config);
    }
}
