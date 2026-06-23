// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title ILBPairErrors
 * @notice Custom errors for gas-efficient error handling in LBPair
 * @dev Using custom errors saves gas compared to require() with strings
 */
interface ILBPairErrors {
    /// @notice Thrown when a zero address is provided where it's not allowed
    error LBPair__ZeroAddress();

    /// @notice Thrown when a zero amount is provided where it's not allowed
    error LBPair__ZeroAmount();

    /// @notice Thrown when bin step is invalid
    /// @param binStep The invalid bin step
    error LBPair__InvalidBinStep(uint16 binStep);

    /// @notice Thrown when slippage tolerance is exceeded
    /// @param amountOut Actual amount out
    /// @param minAmountOut Minimum required amount out
    error LBPair__SlippageExceeded(uint256 amountOut, uint256 minAmountOut);

    /// @notice Thrown when deadline has passed
    /// @param deadline The deadline timestamp
    /// @param currentTime Current block timestamp
    error LBPair__DeadlineExceeded(uint256 deadline, uint256 currentTime);

    /// @notice Thrown when trying to add liquidity with invalid distribution
    error LBPair__InvalidLiquidityDistribution();

    /// @notice Thrown when trying to remove more liquidity than owned
    /// @param shares Shares to remove
    /// @param balance User's balance
    error LBPair__InsufficientShares(uint256 shares, uint256 balance);

    /// @notice Thrown when price moves too much (circuit breaker)
    /// @param fromBinId Starting bin
    /// @param toBinId Ending bin
    /// @param maxMove Maximum allowed move
    error LBPair__ExcessivePriceMove(uint24 fromBinId, uint24 toBinId, uint24 maxMove);

    /// @notice Thrown when active bin would become invalid after operation
    /// @param proposedActiveBin The proposed active bin
    error LBPair__InvalidActiveId(uint24 proposedActiveBin);

    /// @notice Thrown when reentrancy is detected
    error LBPair__Reentrancy();

    /// @notice Thrown when caller is not authorized
    /// @param caller The unauthorized caller
    error LBPair__Unauthorized(address caller);

    /// @notice Thrown when trying to operate during emergency pause
    error LBPair__Paused();

    /// @notice Thrown when token transfer fails
    error LBPair__TransferFailed();

    /// @notice Thrown when too many bins would be crossed in single operation
    /// @param binsCount Number of bins
    /// @param maxBins Maximum allowed bins
    error LBPair__TooManyBins(uint256 binsCount, uint256 maxBins);

    /// @notice Thrown when the first deposit to a bin mints less than the locked minimum liquidity
    error LBPair__InsufficientLiquidityMinted();

    /// @notice Thrown when the post-swap price deviates from the oracle beyond the allowed bins
    /// @param dexBinId Resulting DEX active bin
    /// @param oracleBinId Oracle-implied bin
    /// @param maxDeviationBins Maximum allowed deviation in bins
    error LBPair__OracleDeviationTooHigh(uint24 dexBinId, uint24 oracleBinId, uint24 maxDeviationBins);
}
