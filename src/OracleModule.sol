// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracleModule} from "./interfaces/IOracleModule.sol";
import {ILBPairTypes} from "./interfaces/ILBPairTypes.sol";
import {ILBPair} from "./interfaces/ILBPair.sol";
import {BinMath} from "./libraries/BinMath.sol";
import {FeeHelper} from "./libraries/FeeHelper.sol";

/**
 * @title OracleModule
 * @notice Chainlink oracle integration for price feeds and deviation fees
 * @dev Standalone contract following the ComplianceModule pattern.
 *      Oracle NEVER halts trading or moves the active bin.
 *      If feed is unset or stale, returns safe defaults (0 fee, invalid flag).
 *
 * Two purposes:
 * 1. LP convenience — getOracleBinId() converts Chainlink price to bin ID
 * 2. Fee adjustment — getDeviationFee() adds extra fee when DEX diverges from oracle
 */
contract OracleModule is IOracleModule {
    // =============================================================
    //                          STORAGE
    // =============================================================

    /// @notice Contract owner
    address public owner;

    /// @notice Price feed config per pair
    struct FeedConfig {
        address feed;           // Chainlink aggregator address
        uint256 maxStaleness;   // Max acceptable price age (seconds)
        uint16 binStep;         // Cached bin step for price-to-bin conversion
    }

    /// @notice Feed configuration per pair
    mapping(address => FeedConfig) private _feedConfigs;

    /// @notice Deviation parameters per pair
    mapping(address => ILBPairTypes.OracleDeviationParams) private _deviationParams;

    /// @notice Whether deviation params have been explicitly set for a pair
    mapping(address => bool) private _hasCustomDeviationParams;

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(address _owner) {
        if (_owner == address(0)) revert OracleModule__ZeroAddress();
        owner = _owner;
    }

    // =============================================================
    //                        MODIFIERS
    // =============================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert OracleModule__Unauthorized();
        _;
    }

    // =============================================================
    //                      VIEW FUNCTIONS
    // =============================================================

    /// @inheritdoc IOracleModule
    function getOracleBinId(address pair) external view override returns (uint24 oracleBinId, bool isValid) {
        FeedConfig memory config = _feedConfigs[pair];
        if (config.feed == address(0)) return (0, false);

        (int256 price, , uint256 updatedAt) = _readChainlink(config.feed);

        // Validate: positive price and not stale
        if (price <= 0) return (0, false);
        if (block.timestamp - updatedAt > config.maxStaleness) return (0, false);

        // Convert Chainlink price to 2^128 scaled price
        uint8 feedDecimals = _getDecimals(config.feed);
        uint256 scaledPrice = (uint256(price) * BinMath.SCALE) / (10 ** feedDecimals);

        // Convert scaled price to bin ID
        oracleBinId = BinMath.getIdFromPrice(scaledPrice, config.binStep);
        isValid = true;
    }

    /// @inheritdoc IOracleModule
    function getDeviationFee(address pair, uint24 activeBinId) external view override returns (uint256 deviationFeeBps) {
        FeedConfig memory config = _feedConfigs[pair];
        if (config.feed == address(0)) return 0;

        (int256 price, , uint256 updatedAt) = _readChainlink(config.feed);

        // If invalid or stale, return 0 (no penalty)
        if (price <= 0) return 0;
        if (block.timestamp - updatedAt > config.maxStaleness) return 0;

        // Convert to bin ID
        uint8 feedDecimals = _getDecimals(config.feed);
        uint256 scaledPrice = (uint256(price) * BinMath.SCALE) / (10 ** feedDecimals);
        uint24 oracleBinId = BinMath.getIdFromPrice(scaledPrice, config.binStep);

        // Get deviation params (custom or defaults)
        ILBPairTypes.OracleDeviationParams memory params = _getEffectiveDeviationParams(pair, config.binStep);

        // Calculate fee
        deviationFeeBps = FeeHelper.getOracleDeviationFee(activeBinId, oracleBinId, params);
    }

    /// @inheritdoc IOracleModule
    function getOraclePrice(address pair) external view override returns (int256 price, uint8 decimals, uint256 updatedAt) {
        FeedConfig memory config = _feedConfigs[pair];
        if (config.feed == address(0)) return (0, 0, 0);

        decimals = _getDecimals(config.feed);
        (price, , updatedAt) = _readChainlink(config.feed);
    }

    /// @inheritdoc IOracleModule
    function getDeviationParams(address pair) external view override returns (ILBPairTypes.OracleDeviationParams memory params) {
        FeedConfig memory config = _feedConfigs[pair];
        return _getEffectiveDeviationParams(pair, config.binStep);
    }

    /// @inheritdoc IOracleModule
    function getDefaultDeviationParams(uint16 binStep) external pure override returns (ILBPairTypes.OracleDeviationParams memory params) {
        return _defaultDeviationParams(binStep);
    }

    // =============================================================
    //                     ADMIN FUNCTIONS
    // =============================================================

    /// @inheritdoc IOracleModule
    function setPriceFeed(address pair, address feed, uint256 maxStaleness) external override onlyOwner {
        if (pair == address(0)) revert OracleModule__ZeroAddress();
        if (maxStaleness == 0) revert OracleModule__InvalidParams();

        // Cache the bin step from the pair
        uint16 binStep = ILBPair(pair).binStep();

        _feedConfigs[pair] = FeedConfig({
            feed: feed,
            maxStaleness: maxStaleness,
            binStep: binStep
        });

        emit PriceFeedSet(pair, feed, maxStaleness);
    }

    /// @inheritdoc IOracleModule
    function setDeviationParams(address pair, ILBPairTypes.OracleDeviationParams calldata params) external override onlyOwner {
        if (pair == address(0)) revert OracleModule__ZeroAddress();
        // Validate: tier boundaries must be ordered
        if (params.tier1MaxBins <= params.deadzoneBins) revert OracleModule__InvalidParams();
        if (params.tier2MaxBins <= params.tier1MaxBins) revert OracleModule__InvalidParams();
        if (params.maxDeviationFee == 0) revert OracleModule__InvalidParams();

        _deviationParams[pair] = params;
        _hasCustomDeviationParams[pair] = true;

        emit DeviationParamsSet(pair, params);
    }

    /// @inheritdoc IOracleModule
    function transferOwnership(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert OracleModule__ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // =============================================================
    //                    INTERNAL FUNCTIONS
    // =============================================================

    /**
     * @notice Read Chainlink aggregator — never reverts
     */
    function _readChainlink(address feed) internal view returns (int256 price, uint80 roundId, uint256 updatedAt) {
        try IChainlinkAggregator(feed).latestRoundData() returns (
            uint80 _roundId, int256 _price, uint256, uint256 _updatedAt, uint80
        ) {
            return (_price, _roundId, _updatedAt);
        } catch {
            return (0, 0, 0);
        }
    }

    /**
     * @notice Get decimals from Chainlink aggregator — defaults to 8
     */
    function _getDecimals(address feed) internal view returns (uint8) {
        try IChainlinkAggregator(feed).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 8;
        }
    }

    /**
     * @notice Get effective deviation params (custom if set, otherwise defaults)
     */
    function _getEffectiveDeviationParams(
        address pair,
        uint16 binStep
    ) internal view returns (ILBPairTypes.OracleDeviationParams memory) {
        if (_hasCustomDeviationParams[pair]) {
            return _deviationParams[pair];
        }
        return _defaultDeviationParams(binStep);
    }

    /**
     * @notice Default deviation parameters tuned per bin step tier
     * @dev 10bp = tight (large-cap), 50bp = standard, 100bp = wide (volatile)
     */
    function _defaultDeviationParams(uint16 binStep) internal pure returns (ILBPairTypes.OracleDeviationParams memory) {
        if (binStep <= 10) {
            // Ultra-tight: large-cap stocks, wider deadzone
            return ILBPairTypes.OracleDeviationParams({
                deadzoneBins: 5,
                tier1MaxBins: 20,
                tier1RatePerBin: 2,
                tier2MaxBins: 40,
                tier2RatePerBin: 5,
                maxDeviationFee: 130
            });
        } else if (binStep <= 50) {
            // Standard: mid-cap stocks
            return ILBPairTypes.OracleDeviationParams({
                deadzoneBins: 1,
                tier1MaxBins: 4,
                tier1RatePerBin: 10,
                tier2MaxBins: 8,
                tier2RatePerBin: 25,
                maxDeviationFee: 130
            });
        } else {
            // Wide: small-cap / volatile
            return ILBPairTypes.OracleDeviationParams({
                deadzoneBins: 1,
                tier1MaxBins: 2,
                tier1RatePerBin: 20,
                tier2MaxBins: 4,
                tier2RatePerBin: 50,
                maxDeviationFee: 130
            });
        }
    }
}

/**
 * @notice Minimal Chainlink AggregatorV3 interface
 */
interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}
