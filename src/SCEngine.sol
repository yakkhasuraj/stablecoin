// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Stablecoin} from "./Stablecoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title A sample Stablecoin engine
 * @author Suraj Yakkha
 * @notice You can use this contract for creating a sample Stablecoin engine
 * @dev Governs Stablecoin
 */
contract SCEngine is ReentrancyGuard {
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    Stablecoin private i_sc;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_depositedCollateral;
    mapping(address user => uint256 scAmount) private s_mintedSc;
    address[] s_collateralTokens;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);

    error SCEngine__AmountIsLessThanZero();
    error SCEngine__TokenAndPriceFeedSizeMustBeEqual();
    error SCEngine__IsInvalidToken();
    error SCEngine__TransferFailed();
    error SCEngine__BreaksHealthFactor(uint256 healthFactor);
    error SCEngine__MintFailed();
    error SCEngine__HealthFactorIsOk();
    error SCEngine__HealthFactorHasNotImproved();

    modifier isMoreThanZero(uint256 amount) {
        if (amount == 0) {
            revert SCEngine__AmountIsLessThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert SCEngine__IsInvalidToken();
        }
        _;
    }

    constructor(address[] memory tokens, address[] memory priceFeeds, address stablecoin) {
        if (tokens.length != priceFeeds.length) {
            revert SCEngine__TokenAndPriceFeedSizeMustBeEqual();
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
     * @param scToMint Amount of stablecoin to mint
     */
    function depositCollateralAndMintSC(address collateralAddress, uint256 collateralAmount, uint256 scToMint)
        external
    {
        depositCollateral(collateralAddress, collateralAmount);
        mintSC(scToMint);
    }

    /**
     * @param collateralAddress Address of token to deposit as collateral
     * @param collateralAmount Amount of collateral to deposit
     * @param scToBurn Amount of stablecoin to burn
     */
    function redeemCollateralForSC(address collateralAddress, uint256 collateralAmount, uint256 scToBurn) external {
        burnSC(scToBurn);
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
        if (startingUserHealthFactor >= HEALTH_FACTOR) {
            revert SCEngine__HealthFactorIsOk();
        }

        uint256 collateralAmountFromDebtCovered = getCollateralAmountFromUsd(collateralAddress, debtToCover);
        uint256 bonusCollateral = (collateralAmountFromDebtCovered * LIQUIDATION_PRECISION) / LIQUIDATION_BONUS;
        uint256 totalCollateralToRedeem = collateralAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateralAddress, totalCollateralToRedeem);

        _burnSC(user, msg.sender, debtToCover);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert SCEngine__HealthFactorHasNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

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
            revert SCEngine__TransferFailed();
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
     * @param scToMint Amount of stablecoin to mint
     */
    function mintSC(uint256 scToMint) public isMoreThanZero(scToMint) nonReentrant {
        s_mintedSc[msg.sender] += scToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool success = i_sc.mint(msg.sender, scToMint);
        if (!success) {
            revert SCEngine__MintFailed();
        }
    }

    /**
     * @param amount Amount of stablecoin to burn
     */
    function burnSC(uint256 amount) public isMoreThanZero(amount) {
        _burnSC(msg.sender, msg.sender, amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getCollateralAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getUserCollateral(address user) public view returns (uint256 collateralUsdValue) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_depositedCollateral[user][token];
            collateralUsdValue += getUsdValue(token, amount);
        }
        return collateralUsdValue;
    }

    function _burnSC(address onBehalfOf, address from, uint256 amount) private {
        s_mintedSc[onBehalfOf] -= amount;
        bool success = i_sc.transferFrom(from, address(this), amount);
        if (!success) {
            revert SCEngine__TransferFailed();
        }
        i_sc.burn(amount);
    }

    function _redeemCollateral(address from, address to, address collateralAddress, uint256 collateralAmount) private {
        s_depositedCollateral[from][collateralAddress] -= collateralAmount;
        emit CollateralRedeemed(from, to, collateralAddress, collateralAmount);

        bool success = IERC20(collateralAddress).transfer(to, collateralAmount);
        if (!success) {
            revert SCEngine__TransferFailed();
        }
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < HEALTH_FACTOR) {
            revert SCEngine__BreaksHealthFactor(healthFactor);
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalMintedSc, uint256 collateralValue)
    {
        totalMintedSc = s_mintedSc[user];
        collateralValue = getUserCollateral(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalMintedSc, uint256 collateralValue) = _getAccountInformation(user);
        uint256 adjustedCollateral = (collateralValue * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (adjustedCollateral * PRECISION) / totalMintedSc;
    }
}
