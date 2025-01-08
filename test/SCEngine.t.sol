// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {SCEngine} from "../src/SCEngine.sol";
import {ScEngineScript} from "../script/SCEngine.s.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract SCEngineTest is Test {
    ScEngineScript deployer;
    Stablecoin sc;
    SCEngine scEngine;
    HelperConfig config;
    address ethUsdPriceFee;
    address weth;

    address USER = makeAddr("user");
    uint256 constant AMOUNT_COLLATERAL = 10 ether;
    uint256 constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new ScEngineScript();
        (sc, scEngine, config) = deployer.run();
        (ethUsdPriceFee,, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    function test__GetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expected = 30000e18;
        uint256 actual = scEngine.getUsdValue(weth, ethAmount);
        assertEq(expected, actual);
    }

    function test__RevertWhenCollateralIsZero() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(scEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(SCEngine.SCEngine__AmountIsLessThanZero.selector);
        scEngine.depositCollateral(weth, 0);

        vm.stopPrank();
    }
}
