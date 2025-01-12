// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title MockChainlinkPriceFeed
 * @dev A mock implementation of the Chainlink AggregatorV3Interface for testing purposes.
 */
contract MockChainlinkPriceFeed {
    uint8 public decimals = 8; // Chainlink price feeds typically use 8 decimals
    int256 private price; // The mock price value

    /**
     * @dev Constructor to initialize the mock price feed with an initial price.
     * @param initialPrice The initial price to set (scaled by 10^8).
     */
    constructor(int256 initialPrice) {
        price = initialPrice;
    }

    /**
     * @dev Updates the mock price.
     * @param newPrice The new price to set (scaled by 10^8).
     */
    function setPrice(int256 newPrice) external {
        price = newPrice;
    }

    /**
     * @dev Returns the latest price data.
     * @return roundId The round ID (mock value).
     * @return answer The latest price.
     * @return startedAt The timestamp when the round started (mock value).
     * @return updatedAt The timestamp when the round was updated (mock value).
     * @return answeredInRound The round ID in which the answer was computed (mock value).
     */
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, price, block.timestamp, block.timestamp, 1);
    }

    /**
     * @dev Returns the number of decimals used by the price feed.
     * @return The number of decimals.
     */
    function getDecimals() external view returns (uint8) {
        return decimals;
    }
}