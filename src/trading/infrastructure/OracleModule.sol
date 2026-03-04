// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IOracleModule} from "../domain/ports/IOracleModule.sol";
import {ILBPairTypes} from "../domain/kernel/ILBPairTypes.sol";
import {ILBPair} from "../domain/ports/ILBPair.sol";
import {BinMath} from "../domain/services/BinMath.sol";
import {FeeHelper} from "../domain/services/FeeHelper.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

contract OracleModule is IOracleModule, Initializable {

    address public owner;

    struct FeedConfig {
        address feed;
        uint256 maxStaleness;
        uint16 binStep;
    }

    mapping(address => FeedConfig) private _feedConfigs;

    mapping(address => ILBPairTypes.OracleDeviationParams) private _deviationParams;

    mapping(address => bool) private _hasCustomDeviationParams;

    uint256 public constant MAX_STALENESS = 86400; // 24 hours

    uint256[49] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) external initializer {
        if (_owner == address(0)) revert OracleModule__ZeroAddress();
        owner = _owner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OracleModule__Unauthorized();
        _;
    }

    function getOracleBinId(address pair) external view override returns (uint24 oracleBinId, bool isValid) {
        FeedConfig memory config = _feedConfigs[pair];
        if (config.feed == address(0)) return (0, false);

        (int256 price, , uint256 updatedAt) = _readChainlink(config.feed);

        if (price <= 0) return (0, false);
        if (block.timestamp - updatedAt > config.maxStaleness) return (0, false);

        uint8 feedDecimals = _getDecimals(config.feed);
        uint256 scaledPrice = (uint256(price) * BinMath.SCALE) / (10 ** feedDecimals);

        oracleBinId = BinMath.getIdFromPrice(scaledPrice, config.binStep);
        isValid = true;
    }

    function getDeviationFee(address pair, uint24 activeBinId) external view override returns (uint256 deviationFeeBps) {
        FeedConfig memory config = _feedConfigs[pair];
        if (config.feed == address(0)) return 0;

        (int256 price, , uint256 updatedAt) = _readChainlink(config.feed);

        if (price <= 0) return 0;
        if (block.timestamp - updatedAt > config.maxStaleness) return 0;

        uint8 feedDecimals = _getDecimals(config.feed);
        uint256 scaledPrice = (uint256(price) * BinMath.SCALE) / (10 ** feedDecimals);
        uint24 oracleBinId = BinMath.getIdFromPrice(scaledPrice, config.binStep);

        ILBPairTypes.OracleDeviationParams memory params = _getEffectiveDeviationParams(pair, config.binStep);

        deviationFeeBps = FeeHelper.getOracleDeviationFee(activeBinId, oracleBinId, params);
    }

    function getOraclePrice(address pair) external view override returns (int256 price, uint8 decimals, uint256 updatedAt) {
        FeedConfig memory config = _feedConfigs[pair];
        if (config.feed == address(0)) return (0, 0, 0);

        decimals = _getDecimals(config.feed);
        (price, , updatedAt) = _readChainlink(config.feed);
    }

    function getDeviationParams(address pair) external view override returns (ILBPairTypes.OracleDeviationParams memory params) {
        FeedConfig memory config = _feedConfigs[pair];
        return _getEffectiveDeviationParams(pair, config.binStep);
    }

    function getDefaultDeviationParams(uint16 binStep) external pure override returns (ILBPairTypes.OracleDeviationParams memory params) {
        return _defaultDeviationParams(binStep);
    }

    function setPriceFeed(address pair, address feed, uint256 maxStaleness) external override onlyOwner {
        if (pair == address(0)) revert OracleModule__ZeroAddress();
        if (maxStaleness == 0 || maxStaleness > MAX_STALENESS) revert OracleModule__InvalidParams();

        uint16 binStep = ILBPair(pair).binStep();

        _feedConfigs[pair] = FeedConfig({
            feed: feed,
            maxStaleness: maxStaleness,
            binStep: binStep
        });

        emit PriceFeedSet(pair, feed, maxStaleness);
    }

    function setDeviationParams(address pair, ILBPairTypes.OracleDeviationParams calldata params) external override onlyOwner {
        if (pair == address(0)) revert OracleModule__ZeroAddress();
        if (params.tier1MaxBins <= params.deadzoneBins) revert OracleModule__InvalidParams();
        if (params.tier2MaxBins <= params.tier1MaxBins) revert OracleModule__InvalidParams();
        if (params.maxDeviationFee == 0) revert OracleModule__InvalidParams();

        _deviationParams[pair] = params;
        _hasCustomDeviationParams[pair] = true;

        emit DeviationParamsSet(pair, params);
    }

    address public pendingOwner;

    function transferOwnership(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert OracleModule__ZeroAddress();
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert OracleModule__Unauthorized();
        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    function _readChainlink(address feed) internal view returns (int256 price, uint80 roundId, uint256 updatedAt) {
        try IChainlinkAggregator(feed).latestRoundData() returns (
            uint80 _roundId, int256 _price, uint256, uint256 _updatedAt, uint80
        ) {
            return (_price, _roundId, _updatedAt);
        } catch {
            return (0, 0, 0);
        }
    }

    function _getDecimals(address feed) internal view returns (uint8) {
        try IChainlinkAggregator(feed).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 8;
        }
    }

    function _getEffectiveDeviationParams(
        address pair,
        uint16 binStep
    ) internal view returns (ILBPairTypes.OracleDeviationParams memory) {
        if (_hasCustomDeviationParams[pair]) {
            return _deviationParams[pair];
        }
        return _defaultDeviationParams(binStep);
    }

    function _defaultDeviationParams(uint16 binStep) internal pure returns (ILBPairTypes.OracleDeviationParams memory) {
        if (binStep <= 10) {
            return ILBPairTypes.OracleDeviationParams({
                deadzoneBins: 5,
                tier1MaxBins: 20,
                tier1RatePerBin: 2,
                tier2MaxBins: 40,
                tier2RatePerBin: 5,
                maxDeviationFee: 130
            });
        } else if (binStep <= 50) {
            return ILBPairTypes.OracleDeviationParams({
                deadzoneBins: 1,
                tier1MaxBins: 4,
                tier1RatePerBin: 10,
                tier2MaxBins: 8,
                tier2RatePerBin: 25,
                maxDeviationFee: 130
            });
        } else {
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

interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}
