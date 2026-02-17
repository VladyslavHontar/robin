// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title MockChainlinkAggregator
 * @notice Test mock implementing Chainlink's AggregatorV3Interface
 * @dev Allows setting price and staleness for oracle testing
 */
contract MockChainlinkAggregator {
    uint8 private _decimals;
    int256 private _price;
    uint256 private _updatedAt;
    uint80 private _roundId;

    constructor(uint8 decimals_, int256 initialPrice) {
        _decimals = decimals_;
        _price = initialPrice;
        _updatedAt = block.timestamp;
        _roundId = 1;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, _updatedAt, _updatedAt, _roundId);
    }

    // --- Test helpers ---

    function setPrice(int256 price) external {
        _price = price;
        _updatedAt = block.timestamp;
        _roundId++;
    }

    function setPriceWithTimestamp(int256 price, uint256 timestamp) external {
        _price = price;
        _updatedAt = timestamp;
        _roundId++;
    }

    function setStalePrice(int256 price, uint256 staleBy) external {
        _price = price;
        _updatedAt = block.timestamp - staleBy;
        _roundId++;
    }
}
