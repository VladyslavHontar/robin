// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILBPairTypes} from "../kernel/ILBPairTypes.sol";

/**
 * @title IOracleModule
 * @notice Interface for the oracle module that provides price feeds and deviation fees
 * @dev Oracle serves two purposes:
 *      1. LP convenience — converts Chainlink price to bin ID for positioning
 *      2. Fee deviation — increases fees when DEX price diverges from oracle
 *      Oracle NEVER halts trading or moves the active bin.
 */
interface IOracleModule {

    error OracleModule__Unauthorized();
    error OracleModule__ZeroAddress();
    error OracleModule__InvalidParams();


    event PriceFeedSet(address indexed pair, address indexed feed, uint256 maxStaleness);
    event DeviationParamsSet(address indexed pair, ILBPairTypes.OracleDeviationParams params);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);


    /**
     * @notice Get the oracle-derived bin ID for a pair
     * @dev Reads Chainlink price, scales to 2^128 format, converts to bin ID
     * @param pair The LBPair address
     * @return oracleBinId The bin ID corresponding to the oracle price
     * @return isValid True if the price feed is set, fresh, and positive
     */
    function getOracleBinId(address pair) external view returns (uint24 oracleBinId, bool isValid);

    /**
     * @notice Get the deviation fee for a pair based on active bin vs oracle bin
     * @dev Returns 0 if oracle is not configured or stale. Never reverts.
     * @param pair The LBPair address
     * @param activeBinId The current active bin ID of the pair
     * @return deviationFeeBps Extra fee in basis points due to oracle deviation
     */
    function getDeviationFee(address pair, uint24 activeBinId) external view returns (uint256 deviationFeeBps);

    /**
     * @notice Get the raw oracle price for a pair
     * @param pair The LBPair address
     * @return price The latest price from Chainlink
     * @return decimals The price feed decimals
     * @return updatedAt The timestamp of the last price update
     */
    function getOraclePrice(address pair) external view returns (int256 price, uint8 decimals, uint256 updatedAt);

    /**
     * @notice Get deviation parameters for a pair
     * @param pair The LBPair address
     * @return params The oracle deviation parameters
     */
    function getDeviationParams(address pair) external view returns (ILBPairTypes.OracleDeviationParams memory params);

    /**
     * @notice Get default deviation parameters for a bin step tier
     * @param binStep The bin step (10, 50, or 100)
     * @return params Default parameters tuned for the bin step
     */
    function getDefaultDeviationParams(uint16 binStep) external pure returns (ILBPairTypes.OracleDeviationParams memory params);


    /**
     * @notice Set the Chainlink price feed for a pair
     * @param pair The LBPair address
     * @param feed The Chainlink aggregator address
     * @param maxStaleness Maximum acceptable age of price data (seconds)
     */
    function setPriceFeed(address pair, address feed, uint256 maxStaleness) external;

    /**
     * @notice Set deviation fee parameters for a pair
     * @param pair The LBPair address
     * @param params The oracle deviation parameters
     */
    function setDeviationParams(address pair, ILBPairTypes.OracleDeviationParams calldata params) external;

    /**
     * @notice Transfer ownership of the oracle module (two-step)
     * @param newOwner The new pending owner address
     */
    function transferOwnership(address newOwner) external;

    /**
     * @notice Accept pending ownership transfer
     */
    function acceptOwnership() external;
}
