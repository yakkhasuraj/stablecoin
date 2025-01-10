// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ScEngine} from "../../src/ScEngine.sol";
import {ScEngineScript} from "../../script/ScEngine.s.sol";
import {Stablecoin} from "../../src/Stablecoin.sol";

contract InvariantTest is StdInvariant, Test {
    ScEngineScript deployer;
    Stablecoin sc;
    ScEngine scEngine;
    HelperConfig config;
    Handler handler;

    address weth;
    address wbtc;

    function setUp() public {
        deployer = new ScEngineScript();
        (sc, scEngine, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();

        handler = new Handler(sc, scEngine);
        targetContract(address(handler));
    }

    function invariant_ProtocolValueIsMoreThanTotalSupply() public view {
        uint256 totalSupply = sc.totalSupply();
        uint256 wethAmount = IERC20(weth).balanceOf(address(scEngine));
        uint256 wbtcAmount = IERC20(wbtc).balanceOf(address(scEngine));

        console.log("totalSupply", totalSupply);

        uint256 wethValue = scEngine.getUsdValue(weth, wethAmount);
        uint256 wbtcValue = scEngine.getUsdValue(wbtc, wbtcAmount);

        console.log("wethValue", wethValue);
        console.log("wbtcValue", wbtcValue);

        console.log("numberOfMintCall", handler.numberOfMintCall());

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_GetterShouldNotRevert() public view {
        scEngine.getCollateralTokens();
        scEngine.getPrecision();
        scEngine.getAdditionalFeedPrecision();
        scEngine.getLiquidationThreshold();
        scEngine.getLiquidationBonus();
        scEngine.getMinimumHealthFactor();
    }
}
