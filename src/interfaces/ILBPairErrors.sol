// SPDX-License-Identifier: MIT
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

    /// @notice Thrown when bin ID is invalid or out of range
    /// @param binId The invalid bin ID
    error LBPair__InvalidBinId(uint24 binId);

    /// @notice Thrown when bin step is invalid
    /// @param binStep The invalid bin step
    error LBPair__InvalidBinStep(uint16 binStep);

    /// @notice Thrown when trying to operate on an empty bin
    /// @param binId The empty bin ID
    error LBPair__EmptyBin(uint24 binId);

    /// @notice Thrown when insufficient liquidity in bin for swap
    /// @param binId The bin with insufficient liquidity
    /// @param available Available amount
    /// @param required Required amount
    error LBPair__InsufficientLiquidity(uint24 binId, uint256 available, uint256 required);

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

    /// @notice Thrown when fee parameters are invalid
    error LBPair__InvalidFeeParameters();

    /// @notice Thrown when price moves too much (circuit breaker)
    /// @param fromBinId Starting bin
    /// @param toBinId Ending bin
    /// @param maxMove Maximum allowed move
    error LBPair__ExcessivePriceMove(uint24 fromBinId, uint24 toBinId, uint24 maxMove);

    /// @notice Thrown when active bin would become invalid after operation
    /// @param proposedActiveBin The proposed active bin
    error LBPair__InvalidActiveId(uint24 proposedActiveBin);

    /// @notice Thrown when amounts don't match expected ratio
    error LBPair__InvalidAmountRatio();

    /// @notice Thrown when reentrancy is detected
    error LBPair__Reentrancy();

    /// @notice Thrown when caller is not authorized
    /// @param caller The unauthorized caller
    error LBPair__Unauthorized(address caller);

    /// @notice Thrown when operation would cause overflow
    error LBPair__Overflow();

    /// @notice Thrown when trying to swap with no path available
    error LBPair__NoSwapPath();

    /// @notice Thrown when bitmap is not synced with bin state
    /// @param binId The bin with inconsistent state
    error LBPair__BitmapInconsistency(uint24 binId);

    /// @notice Thrown when trying to operate during emergency pause
    error LBPair__Paused();

    /// @notice Thrown when token transfer fails
    error LBPair__TransferFailed();

    /// @notice Thrown when amounts provided exceed maximum allowed
    /// @param amount Provided amount
    /// @param max Maximum allowed
    error LBPair__AmountTooLarge(uint256 amount, uint256 max);

    /// @notice Thrown when too many bins would be crossed in single operation
    /// @param binsCount Number of bins
    /// @param maxBins Maximum allowed bins
    error LBPair__TooManyBins(uint256 binsCount, uint256 maxBins);

}
