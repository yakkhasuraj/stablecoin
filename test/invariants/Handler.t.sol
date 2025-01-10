// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../MockV3Aggregator.sol";
import {ScEngine} from "../../src/ScEngine.sol";
import {Stablecoin} from "../../src/Stablecoin.sol";

contract Handler is Test {
    Stablecoin sc;
    ScEngine scEngine;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public numberOfMintCall;
    address[] public usersWithCollateral;
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 MAX_DEPOSIT = type(uint96).max;

    constructor(Stablecoin _sc, ScEngine _scEngine) {
        sc = _sc;
        scEngine = _scEngine;

        address[] memory collateralTokens = scEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(scEngine.getTokenPriceFeed(address(weth)));
    }

    function depositCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        collateralAmount = bound(collateralAmount, 1, MAX_DEPOSIT);

        vm.startPrank(msg.sender);

        collateral.mint(msg.sender, collateralAmount);
        collateral.approve(address(scEngine), collateralAmount);

        scEngine.depositCollateral(address(collateral), collateralAmount);

        vm.stopPrank();

        usersWithCollateral.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = scEngine.getCollateralBalanceOfUser(address(collateral), msg.sender);

        collateralAmount = bound(collateralAmount, 0, maxCollateralToRedeem);
        if (collateralAmount == 0) return;

        scEngine.redeemCollateral(address(collateral), collateralAmount);
    }

    function mintSc(uint256 amountOfScToMint, uint256 addressSeed) public {
        if (usersWithCollateral.length == 0) return;
        address sender = usersWithCollateral[addressSeed % usersWithCollateral.length];
        (uint256 totalMintedSc, uint256 collateralValue) = scEngine.getAccountInformation(sender);

        int256 maxScToMint = (int256(collateralValue) / 2) - int256(totalMintedSc);
        if (maxScToMint < 0) return;

        amountOfScToMint = bound(amountOfScToMint, 0, uint256(maxScToMint));
        if (amountOfScToMint == 0) return;

        vm.startPrank(sender);

        scEngine.mintSc(amountOfScToMint);

        vm.stopPrank();

        numberOfMintCall++;
    }

    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInInt);
    // }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) return weth;
        return wbtc;
    }
}
