// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {SCEngine} from "../src/SCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract ScEngineScript is Script {
    address[] public tokens;
    address[] public priceFeeds;

    function run() public returns (Stablecoin, SCEngine, HelperConfig) {
        HelperConfig config = new HelperConfig();

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            config.activeNetworkConfig();

        tokens = [weth, wbtc];
        priceFeeds = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey);

        Stablecoin sc = new Stablecoin();
        SCEngine scEngine = new SCEngine(tokens, priceFeeds, address(sc));
        sc.transferOwnership(address(scEngine));

        vm.stopBroadcast();

        return (sc, scEngine, config);
    }
}
