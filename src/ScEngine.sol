// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleLibrary} from "./OracleLibrary.sol";
import {Stablecoin} from "./Stablecoin.sol";

/**
 * @title A sample Stablecoin engine
 * @author Suraj Yakkha
 * @notice You can use this contract for creating a sample Stablecoin engine
 * @dev Governs Stablecoin
 */
contract ScEngine is ReentrancyGuard {
    using OracleLibrary for AggregatorV3Interface;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant MINIMUM_HEALTH_FACTOR = 1e18;

    Stablecoin private immutable i_sc;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_depositedCollateral;
    mapping(address user => uint256 scAmount) private s_mintedSc;
    address[] private s_collateralTokens;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);

    error ScEngine__AmountIsLessThanOne();
    error ScEngine__TokenAndPriceFeedSizeMustBeEqual();
    error ScEngine__IsInvalidToken(address token);
    error ScEngine__TransferFailed();
    error ScEngine__BreaksHealthFactor(uint256 healthFactor);
    error ScEngine__MintFailed();
    error ScEngine__HealthFactorIsOk();
    error ScEngine__HealthFactorHasNotImproved();

    modifier isMoreThanZero(uint256 amount) {
        if (amount < 1) {
            revert ScEngine__AmountIsLessThanOne();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert ScEngine__IsInvalidToken(token);
        }
        _;
    }

    constructor(address[] memory tokens, address[] memory priceFeeds, address stablecoin) {
        if (tokens.length != priceFeeds.length) {
            revert ScEngine__TokenAndPriceFeedSizeMustBeEqual();
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            s_priceFeeds[tokens[i]] = priceFeeds[i];
            s_collateralTokens.push(tokens[i]);
        }
        i_sc = Stablecoin(stablecoin);
    }

    /**
     * @param collateralAddress Address of token to deposit as collateral
     * @param collateralAmount Amount of collateral to deposit
     * @param amountOfScToMint Amount of stablecoin to mint
     */
    function depositCollateralAndMintSc(address collateralAddress, uint256 collateralAmount, uint256 amountOfScToMint)
        external
    {
        depositCollateral(collateralAddress, collateralAmount);
        mintSc(amountOfScToMint);
    }

    /**
     * @param collateralAddress Address of token to deposit as collateral
     * @param collateralAmount Amount of collateral to deposit
     * @param amountOfScToBurn Amount of stablecoin to burn
     */
    function redeemCollateralForSc(address collateralAddress, uint256 collateralAmount, uint256 amountOfScToBurn)
        external
    {
        burnSc(amountOfScToBurn);
        redeemCollateral(collateralAddress, collateralAmount);
    }

    /**
     * @param collateralAddress Address of collateral to liquidate
     * @param user User who has broken health factor
     * @param debtToCover Amount of Stablecoin to improve user health factor
     */
    function liquidate(address collateralAddress, address user, uint256 debtToCover)
        external
        isMoreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MINIMUM_HEALTH_FACTOR) {
            revert ScEngine__HealthFactorIsOk();
        }

        uint256 collateralAmountFromDebtCovered = getCollateralAmountFromUsd(collateralAddress, debtToCover);
        uint256 bonusCollateral = (collateralAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = collateralAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateralAddress, totalCollateralToRedeem);

        _burnSc(user, msg.sender, debtToCover);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert ScEngine__HealthFactorHasNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function calculateHealthFactor(uint256 totalMintedSc, uint256 collateralValue) external pure returns (uint256) {
        return _calculateHealthFactor(totalMintedSc, collateralValue);
    }

    /**
     * @param collateralAddress Address of token to deposit as collateral
     * @param collateralAmount Amount of collateral to deposit
     */
    function depositCollateral(address collateralAddress, uint256 collateralAmount)
        public
        isMoreThanZero(collateralAmount)
        isAllowedToken(collateralAddress)
        nonReentrant
    {
        s_depositedCollateral[msg.sender][collateralAddress] += collateralAmount;
        emit CollateralDeposited(msg.sender, collateralAddress, collateralAmount);

        bool success = IERC20(collateralAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) {
            revert ScEngine__TransferFailed();
        }
    }

    /**
     * @param collateralAddress Address of token to redeem collateral
     * @param collateralAmount Amount of collateral to redeem
     */
    function redeemCollateral(address collateralAddress, uint256 collateralAmount)
        public
        isMoreThanZero(collateralAmount)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, collateralAddress, collateralAmount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param amountOfScToMint Amount of stablecoin to mint
     */
    function mintSc(uint256 amountOfScToMint) public isMoreThanZero(amountOfScToMint) nonReentrant {
        s_mintedSc[msg.sender] += amountOfScToMint;
        _revertIfHealthFactorIsBroken(msg.sender);

        bool success = i_sc.mint(msg.sender, amountOfScToMint);
        if (!success) {
            revert ScEngine__MintFailed();
        }
    }

    /**
     * @param amount Amount of stablecoin to burn
     */
    function burnSc(uint256 amount) public isMoreThanZero(amount) {
        _burnSc(msg.sender, msg.sender, amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalMintedSc, uint256 collateralValue)
    {
        return _getAccountInformation(user);
    }

    function getCollateralAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.checkStaleLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.checkStaleLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getCollateralOfUser(address user) public view returns (uint256 collateralUsdValue) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_depositedCollateral[user][token];
            collateralUsdValue += getUsdValue(token, amount);
        }
        return collateralUsdValue;
    }

    function getCollateralTokens() public view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getTokenPriceFeed(address token) public view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_depositedCollateral[user][token];
    }

    function getPrecision() public pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() public pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() public pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() public pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getMinimumHealthFactor() public pure returns (uint256) {
        return MINIMUM_HEALTH_FACTOR;
    }

    function _burnSc(address onBehalfOf, address from, uint256 amount) private {
        s_mintedSc[onBehalfOf] -= amount;

        bool success = i_sc.transferFrom(from, address(this), amount);
        if (!success) {
            revert ScEngine__TransferFailed();
        }

        i_sc.burn(amount);
    }

    function _redeemCollateral(address from, address to, address collateralAddress, uint256 collateralAmount) private {
        s_depositedCollateral[from][collateralAddress] -= collateralAmount;
        emit CollateralRedeemed(from, to, collateralAddress, collateralAmount);

        bool success = IERC20(collateralAddress).transfer(to, collateralAmount);
        if (!success) {
            revert ScEngine__TransferFailed();
        }
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MINIMUM_HEALTH_FACTOR) {
            revert ScEngine__BreaksHealthFactor(healthFactor);
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalMintedSc, uint256 collateralValue)
    {
        totalMintedSc = s_mintedSc[user];
        collateralValue = getCollateralOfUser(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalMintedSc, uint256 collateralValue) = _getAccountInformation(user);
        // uint256 adjustedCollateral = (collateralValue * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // return (adjustedCollateral * PRECISION) / totalMintedSc;
        return _calculateHealthFactor(totalMintedSc, collateralValue);
    }

    function _calculateHealthFactor(uint256 totalMintedSc, uint256 collateralValue) internal pure returns (uint256) {
        if (totalMintedSc == 0) return type(uint256).max;

        uint256 collateralAdjustedForThreshold = (collateralValue * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * 1e18) / totalMintedSc;
    }
}
