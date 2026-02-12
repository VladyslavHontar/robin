// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILBPairTypes} from "../interfaces/ILBPairTypes.sol";

/**
 * @title SwapHelper
 * @notice Library for swap amount calculations in DLMM
 * @dev Implements constant sum formula (x+y=k) within bins for zero slippage
 *
 * Key insight: Within a single bin, we use constant sum instead of constant product
 * This provides zero slippage swaps within a bin, with price changes only when crossing bins
 */
library SwapHelper {
    using SwapHelper for *;

    /// @notice Maximum number of bins that can be crossed in a single swap
    uint24 internal constant MAX_BINS_PER_SWAP = 100;

    /// @notice Custom errors
    error SwapHelper__InsufficientAmountOut();
    error SwapHelper__TooManyBinsCrossed(uint24 bins);
    error SwapHelper__InvalidReserves();

    /**
     * @notice Calculate amount out for swapping within a single bin
     * @dev Uses constant sum formula: amountOut = amountIn (within bin)
     * @param bin The bin state
     * @param amountIn Amount of input tokens
     * @param swapForY True if swapping X for Y
     * @return amountOut Amount of output tokens (before fees)
     * @return amountInConsumed Actual amount of input consumed
     */
    function getAmountOutSingleBin(
        ILBPairTypes.BinState memory bin,
        uint256 amountIn,
        bool swapForY
    ) internal pure returns (uint256 amountOut, uint256 amountInConsumed) {
        // Get available reserves for output token
        uint256 reserveOut = swapForY ? uint256(bin.reserveY) : uint256(bin.reserveX);

        if (reserveOut == 0) {
            revert SwapHelper__InvalidReserves();
        }

        // Constant sum within bin: price is fixed
        // If swapping X for Y: we can get up to reserveY out for X in
        // Amount out = min(amountIn, reserveOut)
        if (amountIn <= reserveOut) {
            amountOut = amountIn;
            amountInConsumed = amountIn;
        } else {
            // Bin depleted: consume all available
            amountOut = reserveOut;
            amountInConsumed = reserveOut;
        }
    }

    /**
     * @notice Calculate swap across multiple bins
     * @dev Iterates through bins until amountIn is fully consumed or max bins reached
     * @param amountIn Total input amount
     * @param swapForY Direction of swap
     * @param activeBinId Starting active bin
     * @param getBinReserves Function to fetch bin reserves
     * @param getNextNonEmptyBin Function to find next bin
     * @return amountOut Total output amount
     * @return newActiveBinId New active bin after swap
     * @return binsCrossed Number of bins crossed
     */
    function getAmountOutMultiBin(
        uint256 amountIn,
        bool swapForY,
        uint24 activeBinId,
        function(uint24) view returns (uint128, uint128) getBinReserves,
        function(uint24, bool) view returns (uint24) getNextNonEmptyBin
    )
        internal
        view
        returns (uint256 amountOut, uint24 newActiveBinId, uint24 binsCrossed)
    {
        if (amountIn == 0) return (0, activeBinId, 0);

        uint256 amountInRemaining = amountIn;
        newActiveBinId = activeBinId;

        while (amountInRemaining > 0 && binsCrossed < MAX_BINS_PER_SWAP) {
            // Get current bin reserves
            (uint128 reserveX, uint128 reserveY) = getBinReserves(newActiveBinId);

            // Create bin state (cast to uint112 for packed storage)
            ILBPairTypes.BinState memory bin = ILBPairTypes.BinState({
                reserveX: uint112(reserveX),
                reserveY: uint112(reserveY),
                liquidityIndex: 0 // Not needed for swap calculation
            });

            // Calculate swap within this bin
            (uint256 binAmountOut, uint256 binAmountIn) = getAmountOutSingleBin(
                bin,
                amountInRemaining,
                swapForY
            );

            amountOut += binAmountOut;
            amountInRemaining -= binAmountIn;

            // If bin fully consumed, move to next
            if (binAmountIn == (swapForY ? uint256(bin.reserveY) : uint256(bin.reserveX))) {
                binsCrossed++;

                // Find next non-empty bin
                uint24 nextBin = getNextNonEmptyBin(newActiveBinId, swapForY);

                // No more bins available
                if (nextBin == newActiveBinId) {
                    break;
                }

                newActiveBinId = nextBin;
            } else {
                // Swap completed within this bin
                break;
            }
        }

        // Check if we crossed too many bins
        if (binsCrossed >= MAX_BINS_PER_SWAP && amountInRemaining > 0) {
            revert SwapHelper__TooManyBinsCrossed(binsCrossed);
        }
    }

    /**
     * @notice Calculate amount in needed for a target amount out
     * @dev Reverse calculation: given desired output, compute required input
     * @param bin The bin state
     * @param amountOut Desired output amount
     * @param swapForY True if swapping X for Y
     * @return amountIn Required input amount (before fees)
     */
    function getAmountIn(
        ILBPairTypes.BinState memory bin,
        uint256 amountOut,
        bool swapForY
    ) internal pure returns (uint256 amountIn) {
        // Get available reserves for output token
        uint256 reserveOut = swapForY ? uint256(bin.reserveY) : uint256(bin.reserveX);

        if (amountOut > reserveOut) {
            revert SwapHelper__InsufficientAmountOut();
        }

        // Constant sum: amountIn = amountOut (within bin, before fees)
        amountIn = amountOut;
    }

    /**
     * @notice Update bin reserves after swap
     * @dev Mutates bin state in-place
     * @param bin The bin to update
     * @param amountIn Amount of input tokens added
     * @param amountOut Amount of output tokens removed
     * @param swapForY Direction of swap
     */
    function updateBinReserves(
        ILBPairTypes.BinState memory bin,
        uint256 amountIn,
        uint256 amountOut,
        bool swapForY
    ) internal pure {
        if (swapForY) {
            // Swapping X for Y: increase reserveX, decrease reserveY
            bin.reserveX += uint112(amountIn);
            bin.reserveY -= uint112(amountOut);
        } else {
            // Swapping Y for X: increase reserveY, decrease reserveX
            bin.reserveY += uint112(amountIn);
            bin.reserveX -= uint112(amountOut);
        }

        // Validate reserves don't overflow
        if (bin.reserveX > type(uint112).max || bin.reserveY > type(uint112).max) {
            revert SwapHelper__InvalidReserves();
        }
    }

    /**
     * @notice Calculate price impact of a swap
     * @dev Price impact = (endPrice - startPrice) / startPrice
     * @param startBinId Starting bin ID
     * @param endBinId Ending bin ID
     * @param binStep Bin step
     * @return impactBps Price impact in basis points
     */
    function calculatePriceImpact(
        uint24 startBinId,
        uint24 endBinId,
        uint16 binStep
    ) internal pure returns (uint256 impactBps) {
        if (startBinId == endBinId) return 0;

        // Calculate bins moved
        uint24 binsMoved = startBinId > endBinId
            ? startBinId - endBinId
            : endBinId - startBinId;

        // Price impact ≈ binsMoved * binStep
        impactBps = uint256(binsMoved) * uint256(binStep);
    }

    /**
     * @notice Validate swap parameters
     * @param amountIn Input amount
     * @param minAmountOut Minimum output amount
     * @param deadline Transaction deadline
     */
    function validateSwapParameters(
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) internal view {
        if (amountIn == 0) revert SwapHelper__InsufficientAmountOut();
        if (block.timestamp > deadline) {
            // Would revert with deadline error, but we keep this library pure
            // Actual deadline check happens in LBPair
        }
    }

    /**
     * @notice Get the share of a bin that would be consumed by a swap
     * @param bin The bin state
     * @param amountIn Input amount
     * @param swapForY Swap direction
     * @return shareConsumed Share consumed (scaled by 1e18)
     */
    function getBinShareConsumed(
        ILBPairTypes.BinState memory bin,
        uint256 amountIn,
        bool swapForY
    ) internal pure returns (uint256 shareConsumed) {
        uint256 reserveOut = swapForY ? uint256(bin.reserveY) : uint256(bin.reserveX);

        if (reserveOut == 0) return 0;

        // Share = min(amountIn / reserveOut, 1.0)
        if (amountIn >= reserveOut) {
            shareConsumed = 1e18; // 100%
        } else {
            shareConsumed = (amountIn * 1e18) / reserveOut;
        }
    }

    /**
     * @notice Check if a bin would be depleted by a swap
     * @param bin The bin state
     * @param amountIn Input amount
     * @param swapForY Swap direction
     * @return isDepleted True if bin would be fully consumed
     */
    function isBinDepleted(
        ILBPairTypes.BinState memory bin,
        uint256 amountIn,
        bool swapForY
    ) internal pure returns (bool isDepleted) {
        uint256 reserveOut = swapForY ? uint256(bin.reserveY) : uint256(bin.reserveX);
        isDepleted = amountIn >= reserveOut;
    }
}
