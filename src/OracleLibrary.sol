// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title A sample Oracle Library
 * @author Suraj Yakkha
 * @notice You can use this contract to check stale data of Chainlink Oracle
 */
library OracleLibrary {
    uint256 private constant TIMEOUT = 3 hours;

    error OracleLibrary__PriceIsStale();

    function checkStaleLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        if (updatedAt == 0 || answeredInRound < roundId) revert OracleLibrary__PriceIsStale();

        uint256 differenceInSeconds = block.timestamp - updatedAt;
        if (differenceInSeconds > TIMEOUT) revert OracleLibrary__PriceIsStale();

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
