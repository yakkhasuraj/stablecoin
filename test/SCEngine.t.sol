// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {SCEngine} from "../src/SCEngine.sol";
import {ScEngineScript} from "../script/SCEngine.s.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {MockV3Aggregator} from "./MockV3Aggregator.sol";

contract SCEngineTest is StdCheats, Test {
    ScEngineScript deployer;
    Stablecoin sc;
    SCEngine scEngine;
    HelperConfig config;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    uint256 collateralAmount = 10 ether;
    uint256 amountToMint = 100 ether;

    address USER = makeAddr("user");
    uint256 constant AMOUNT_COLLATERAL = 10 ether;
    uint256 constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant MINIMUM_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    address[] public tokens;
    address[] public priceFeeds;

    address liquidator = makeAddr("liquidator");
    uint256 collateralToCover = 20 ether;

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(scEngine), AMOUNT_COLLATERAL);
        scEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositCollateralAndMintSC() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(scEngine), AMOUNT_COLLATERAL);
        scEngine.depositCollateralAndMintSc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        _;
    }

    modifier liquidate() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(scEngine), collateralAmount);
        scEngine.depositCollateralAndMintSc(weth, collateralAmount, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = scEngine.getHealthFactor(USER);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(scEngine), collateralToCover);
        scEngine.depositCollateralAndMintSc(weth, collateralToCover, amountToMint);
        sc.approve(address(scEngine), amountToMint);
        scEngine.liquidate(weth, USER, amountToMint);
        vm.stopPrank();

        _;
    }

    function setUp() public {
        deployer = new ScEngineScript();
        (sc, scEngine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        vm.deal(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    function test__RevertIfTokenAndPriceFeedSizeIsNotEqual() public {
        tokens.push(weth);
        priceFeeds.push(ethUsdPriceFeed);
        priceFeeds.push(btcUsdPriceFeed);

        vm.expectRevert(SCEngine.SCEngine__TokenAndPriceFeedSizeMustBeEqual.selector);
        new SCEngine(tokens, priceFeeds, address(sc));
    }

    function test__GetCollateralAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expected = 0.05 ether;
        uint256 actual = scEngine.getCollateralAmountFromUsd(weth, usdAmount);
        assertEq(expected, actual);
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
        vm.expectRevert(SCEngine.SCEngine__AmountIsLessThanOne.selector);
        scEngine.depositCollateral(weth, 0);

        vm.stopPrank();
    }

    function test__RevertWhenCollateralIsDisallowed() public {
        ERC20Mock randomToken = new ERC20Mock();

        vm.startPrank(USER);

        vm.expectRevert(abi.encodeWithSelector(SCEngine.SCEngine__IsInvalidToken.selector, address(randomToken)));
        scEngine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    function test__DepositCollateralWithoutMinting() public depositCollateral {
        uint256 balance = sc.balanceOf(USER);
        assertEq(balance, 0);
    }

    function test__DepositCollateralAndGetAccountInformation() public depositCollateral {
        (uint256 totalMintedSc, uint256 collateralValue) = scEngine.getAccountInformation(USER);

        uint256 expectedTotalMintedSc = 0;
        uint256 expectedDepositedAmount = scEngine.getCollateralAmountFromUsd(weth, collateralValue);

        assertEq(totalMintedSc, expectedTotalMintedSc);
        assertEq(AMOUNT_COLLATERAL, expectedDepositedAmount);
    }

    function test__RevertIfMintingBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint =
            (collateralAmount * (uint256(price) * scEngine.getAdditionalFeedPrecision())) / scEngine.getPrecision();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(scEngine), collateralAmount);

        uint256 expectedHealthFactor =
            scEngine.calculateHealthFactor(scEngine.getUsdValue(weth, collateralAmount), amountToMint);
        vm.expectRevert(abi.encodeWithSelector(SCEngine.SCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        scEngine.depositCollateralAndMintSc(weth, collateralAmount, amountToMint);
        vm.stopPrank();
    }

    function test__CanMintWithDepositedCollateral() public depositCollateralAndMintSC {
        uint256 userBalance = sc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    function test__RevertIfAmountOfScToMintIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(scEngine), collateralAmount);
        scEngine.depositCollateralAndMintSc(weth, collateralAmount, amountToMint);
        vm.expectRevert(SCEngine.SCEngine__AmountIsLessThanOne.selector);
        scEngine.mintSc(0);
        vm.stopPrank();
    }

    function test__RevertIfAmountOfScToMintBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint =
            (collateralAmount * (uint256(price) * scEngine.getAdditionalFeedPrecision())) / scEngine.getPrecision();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(scEngine), collateralAmount);
        scEngine.depositCollateral(weth, collateralAmount);

        uint256 expectedHealthFactor =
            scEngine.calculateHealthFactor(scEngine.getUsdValue(weth, collateralAmount), amountToMint);
        vm.expectRevert(abi.encodeWithSelector(SCEngine.SCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        scEngine.mintSc(amountToMint);
        vm.stopPrank();
    }

    function test__MintSc() public depositCollateral {
        vm.prank(USER);
        scEngine.mintSc(amountToMint);

        uint256 userBalance = sc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    function test__RevertIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(scEngine), collateralAmount);
        scEngine.depositCollateralAndMintSc(weth, collateralAmount, amountToMint);
        vm.expectRevert(SCEngine.SCEngine__AmountIsLessThanOne.selector);
        scEngine.burnSc(0);
        vm.stopPrank();
    }

    function test__RevertIfAmountOfScToBurnIsMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        scEngine.burnSc(1);
    }

    function test__BurnSc() public depositCollateralAndMintSC {
        vm.startPrank(USER);
        sc.approve(address(scEngine), amountToMint);
        scEngine.burnSc(amountToMint);
        vm.stopPrank();

        uint256 userBalance = sc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function test__RevertIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(scEngine), collateralAmount);
        scEngine.depositCollateralAndMintSc(weth, collateralAmount, amountToMint);
        vm.expectRevert(SCEngine.SCEngine__AmountIsLessThanOne.selector);
        scEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function test_RedeemCollateral() public depositCollateral {
        vm.startPrank(USER);
        scEngine.redeemCollateral(weth, collateralAmount);
        uint256 balance = ERC20Mock(weth).balanceOf(USER);
        assertEq(balance, collateralAmount);
        vm.stopPrank();
    }

    function test__RevertIfRedeemAmountOfScIsZero() public depositCollateralAndMintSC {
        vm.startPrank(USER);
        sc.approve(address(scEngine), amountToMint);
        vm.expectRevert(SCEngine.SCEngine__AmountIsLessThanOne.selector);
        scEngine.redeemCollateralForSc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function test__RedeemSc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(scEngine), collateralAmount);
        scEngine.depositCollateralAndMintSc(weth, collateralAmount, amountToMint);
        sc.approve(address(scEngine), amountToMint);
        scEngine.redeemCollateralForSc(weth, collateralAmount, amountToMint);
        vm.stopPrank();

        uint256 userBalance = sc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function test__GetHealthFactor() public depositCollateralAndMintSC {
        uint256 expected = 100 ether;
        uint256 actual = scEngine.getHealthFactor(USER);
        assertEq(actual, expected);
    }

    function test__HealthFactorGoesBelowOne() public depositCollateralAndMintSC {
        int256 ethUsdUpdatedPrice = 18e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 healthFactor = scEngine.getHealthFactor(USER);
        assert(healthFactor == 0.9 ether);
    }

    function test__BlockLiquidationWhenHealthFactorIsGood() public depositCollateral {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(scEngine), collateralToCover);
        scEngine.depositCollateralAndMintSc(weth, collateralToCover, amountToMint);
        sc.approve(address(scEngine), amountToMint);

        vm.expectRevert(SCEngine.SCEngine__HealthFactorIsOk.selector);
        scEngine.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
    }

    function test__GetLiquidationPayout() public liquidate {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expected = scEngine.getCollateralAmountFromUsd(weth, amountToMint)
            + (scEngine.getCollateralAmountFromUsd(weth, amountToMint) / scEngine.getLiquidationBonus());
        assertEq(liquidatorWethBalance, expected);
    }

    function test__GetUserLiquidatedCollateralAmount() public liquidate {
        uint256 liquidatedAmount = scEngine.getCollateralAmountFromUsd(weth, amountToMint)
            + (scEngine.getCollateralAmountFromUsd(weth, amountToMint) / scEngine.getLiquidationBonus());

        uint256 liquidatedAmountInUsd = scEngine.getUsdValue(weth, liquidatedAmount);
        uint256 expected = scEngine.getUsdValue(weth, collateralAmount) - (liquidatedAmountInUsd);

        (, uint256 collateralValue) = scEngine.getAccountInformation(USER);
        assertEq(collateralValue, expected);
    }

    function test__LiquidatorCoversUsersDebt() public liquidate {
        (uint256 totalMintedSc,) = scEngine.getAccountInformation(liquidator);
        assertEq(totalMintedSc, amountToMint);
    }

    function test__UserHasNoMoreDebt() public liquidate {
        (uint256 totalMintedSc,) = scEngine.getAccountInformation(USER);
        assertEq(totalMintedSc, 0);
    }

    function test__GetCollateralTokenPriceFeed() public view {
        address priceFeed = scEngine.getTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function test__GetCollateralTokens() public view {
        address[] memory collateral = scEngine.getCollateralTokens();
        assertEq(collateral[0], weth);
    }

    function test__GetMinimumHealthFactor() public view {
        uint256 minimumHealthFactor = scEngine.getMinimumHealthFactor();
        assertEq(minimumHealthFactor, MINIMUM_HEALTH_FACTOR);
    }

    function test__GetLiquidationThreshold() public view {
        uint256 threshold = scEngine.getLiquidationThreshold();
        assertEq(threshold, LIQUIDATION_THRESHOLD);
    }

    function test__GetAccountCollateralValue() public depositCollateral {
        (, uint256 collateralValue) = scEngine.getAccountInformation(USER);
        uint256 expected = scEngine.getUsdValue(weth, collateralAmount);
        assertEq(collateralValue, expected);
    }
}
