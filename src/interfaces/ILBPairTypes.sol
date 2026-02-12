// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ILBPairTypes
 * @notice Type definitions for LBPair
 * @dev Centralized struct definitions for clear separation of concerns
 */
interface ILBPairTypes {
    /**
     * @notice Bin state stored in packed format
     * @dev Packed into single uint256 for gas efficiency
     * @param reserveX Token X reserves (112 bits)
     * @param reserveY Token Y reserves (112 bits)
     * @param liquidityIndex Index to liquidity data mapping (32 bits)
     */
    struct BinState {
        uint112 reserveX;
        uint112 reserveY;
        uint32 liquidityIndex;
    }

    /**
     * @notice Liquidity data for a bin (accessed less frequently)
     * @param totalShares Total LP shares in this bin
     * @param feeGrowthX Accumulated fee per share for token X
     * @param feeGrowthY Accumulated fee per share for token Y
     */
    struct LiquidityData {
        uint128 totalShares;
        uint128 feeGrowthX;
        uint128 feeGrowthY;
    }

    /**
     * @notice Fee parameters for the pair
     * @param baseFee Base trading fee in basis points
     * @param protocolShare Protocol's share of fees in basis points
     * @param maxVolatilityFee Maximum additional fee during volatility
     * @param volatilityReference Reference bin for volatility calculation
     * @param filterPeriod Smoothing period for volatility
     * @param decayPeriod Fee decay period
     * @param reductionFactor Volatility fee reduction factor
     */
    struct FeeParameters {
        uint16 baseFee;
        uint16 protocolShare;
        uint16 maxVolatilityFee;
        uint24 volatilityReference;
        uint16 filterPeriod;
        uint16 decayPeriod;
        uint24 reductionFactor;
    }

    /**
     * @notice Parameters for adding liquidity
     * @param binIds Array of bin IDs to add liquidity to
     * @param distributionX Distribution of token X across bins (scaled by 1e18)
     * @param distributionY Distribution of token Y across bins (scaled by 1e18)
     * @param amountX Total amount of token X to add
     * @param amountY Total amount of token Y to add
     * @param activeIdDesired Desired active bin ID
     * @param idSlippage Allowed slippage in bin IDs
     * @param deadline Transaction deadline
     * @param to Recipient of LP shares
     */
    struct LiquidityParameters {
        uint24[] binIds;
        uint64[] distributionX;
        uint64[] distributionY;
        uint256 amountX;
        uint256 amountY;
        uint24 activeIdDesired;
        uint24 idSlippage;
        uint256 deadline;
        address to;
    }

    /**
     * @notice Parameters for removing liquidity
     * @param binIds Array of bin IDs to remove liquidity from
     * @param shares Array of share amounts to burn
     * @param minAmountX Minimum amount of token X to receive
     * @param minAmountY Minimum amount of token Y to receive
     * @param deadline Transaction deadline
     * @param to Recipient of tokens
     */
    struct RemoveLiquidityParameters {
        uint24[] binIds;
        uint256[] shares;
        uint256 minAmountX;
        uint256 minAmountY;
        uint256 deadline;
        address to;
    }

    /**
     * @notice Parameters for executing a swap
     * @param swapForY True if swapping X for Y, false for Y for X
     * @param amountIn Amount of input tokens
     * @param minAmountOut Minimum amount of output tokens
     * @param deadline Transaction deadline
     * @param to Recipient of output tokens
     */
    struct SwapParameters {
        bool swapForY;
        uint256 amountIn;
        uint256 minAmountOut;
        uint256 deadline;
        address to;
    }

    /**
     * @notice Result of a swap operation
     * @param amountOut Amount of output tokens
     * @param fees Total fees collected
     * @param newActiveBinId Active bin ID after swap
     */
    struct SwapResult {
        uint256 amountOut;
        uint256 fees;
        uint24 newActiveBinId;
    }

    /**
     * @notice Oracle data for a bin
     * @param cumulativeId Cumulative bin ID (for TWAP)
     * @param cumulativeVolatility Cumulative volatility
     * @param timestamp Last update timestamp
     */
    struct OracleData {
        uint256 cumulativeId;
        uint256 cumulativeVolatility;
        uint40 timestamp;
    }
}
