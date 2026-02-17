// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILBPairTypes} from "../interfaces/ILBPairTypes.sol";

/**
 * @title FeeHelper
 * @notice Library for calculating dynamic trading fees in DLMM
 * @dev Implements base fee + volatility-based fee with time-sensitive adjustments for stock trading
 *
 * Fee Structure:
 * - Base Fee: Constant fee (e.g., 0.3%)
 * - Volatility Fee: Dynamic fee that increases when price moves rapidly
 * - Oracle Deviation Fee: Extra fee when DEX price diverges from oracle
 * - Time Adjustment: Lower fees during market hours, higher during off-hours
 */
library FeeHelper {
    /// @notice Maximum total fee (1000 bp = 10%)
    uint256 internal constant MAX_TOTAL_FEE = 1000;

    /// @notice Basis points scale
    uint256 internal constant BASIS_POINT_MAX = 10_000;

    /// @notice Market hours start (UTC) - 13:30 = 9:30am ET
    uint256 internal constant MARKET_OPEN_HOUR = 13;
    uint256 internal constant MARKET_OPEN_MINUTE = 30;

    /// @notice Market hours end (UTC) - 20:00 = 4:00pm ET
    uint256 internal constant MARKET_CLOSE_HOUR = 20;

    /// @notice Off-hours fee multiplier (1.5x)
    uint256 internal constant OFF_HOURS_MULTIPLIER = 15_000; // 1.5 in basis points

    /// @notice Custom errors
    error FeeHelper__InvalidFeeParameters();
    error FeeHelper__FeeTooHigh();

    /**
     * @notice Calculate total fee for a swap
     * @dev Total = baseFee + volatilityFee (+ timeAdjustment for stocks)
     * @param feeParams Fee parameters
     * @param activeBinId Current active bin
     * @param targetBinId Target bin after swap
     * @return totalFeeBps Total fee in basis points
     */
    function getTotalFee(
        ILBPairTypes.FeeParameters memory feeParams,
        uint24 activeBinId,
        uint24 targetBinId
    ) internal view returns (uint256 totalFeeBps) {
        // Start with base fee
        totalFeeBps = feeParams.baseFee;

        // Add volatility fee if price is moving
        if (activeBinId != targetBinId) {
            uint256 volatilityFee = getVolatilityFee(feeParams, activeBinId, targetBinId);
            totalFeeBps += volatilityFee;
        }

        // Apply time-based adjustment (stock trading optimization)
        totalFeeBps = applyTimeAdjustment(totalFeeBps);

        // Cap at maximum
        if (totalFeeBps > MAX_TOTAL_FEE) {
            totalFeeBps = MAX_TOTAL_FEE;
        }
    }

    /**
     * @notice Calculate total fee including oracle deviation
     * @dev Total = baseFee + volatilityFee + oracleDeviationFee (+ timeAdjustment)
     * @param feeParams Fee parameters
     * @param activeBinId Current active bin
     * @param targetBinId Target bin after swap
     * @param oracleDeviationFeeBps Extra fee from oracle deviation (0 if no oracle)
     * @return totalFeeBps Total fee in basis points
     */
    function getTotalFee(
        ILBPairTypes.FeeParameters memory feeParams,
        uint24 activeBinId,
        uint24 targetBinId,
        uint256 oracleDeviationFeeBps
    ) internal view returns (uint256 totalFeeBps) {
        // Start with base fee
        totalFeeBps = feeParams.baseFee;

        // Add volatility fee if price is moving
        if (activeBinId != targetBinId) {
            uint256 volatilityFee = getVolatilityFee(feeParams, activeBinId, targetBinId);
            totalFeeBps += volatilityFee;
        }

        // Add oracle deviation fee
        totalFeeBps += oracleDeviationFeeBps;

        // Apply time-based adjustment (stock trading optimization)
        totalFeeBps = applyTimeAdjustment(totalFeeBps);

        // Cap at maximum
        if (totalFeeBps > MAX_TOTAL_FEE) {
            totalFeeBps = MAX_TOTAL_FEE;
        }
    }

    /**
     * @notice Calculate oracle deviation fee using piecewise linear formula
     * @dev Fee increases with bin distance from oracle:
     *      - Within deadzone: 0
     *      - Tier 1: linear slope (gentle)
     *      - Tier 2: linear slope (steep)
     *      - Beyond tier 2: capped at maxDeviationFee
     * @param activeBinId Current DEX active bin
     * @param oracleBinId Oracle-derived bin ID
     * @param params Deviation fee parameters
     * @return feeBps Oracle deviation fee in basis points
     */
    function getOracleDeviationFee(
        uint24 activeBinId,
        uint24 oracleBinId,
        ILBPairTypes.OracleDeviationParams memory params
    ) internal pure returns (uint256 feeBps) {
        // Calculate absolute bin distance
        uint256 deviation = activeBinId > oracleBinId
            ? uint256(activeBinId - oracleBinId)
            : uint256(oracleBinId - activeBinId);

        // Deadzone: no extra fee
        if (deviation <= params.deadzoneBins) {
            return 0;
        }

        // Tier 1: gentle slope
        uint256 binsInTier1;
        if (deviation <= params.tier1MaxBins) {
            binsInTier1 = deviation - params.deadzoneBins;
            feeBps = binsInTier1 * params.tier1RatePerBin;
            return feeBps > params.maxDeviationFee ? params.maxDeviationFee : feeBps;
        }

        // Full tier 1 fee
        binsInTier1 = uint256(params.tier1MaxBins) - uint256(params.deadzoneBins);
        uint256 tier1Fee = binsInTier1 * params.tier1RatePerBin;

        // Tier 2: steeper slope
        if (deviation <= params.tier2MaxBins) {
            uint256 binsInTier2 = deviation - params.tier1MaxBins;
            feeBps = tier1Fee + binsInTier2 * params.tier2RatePerBin;
            return feeBps > params.maxDeviationFee ? params.maxDeviationFee : feeBps;
        }

        // Beyond tier 2: capped
        return params.maxDeviationFee;
    }

    /**
     * @notice Calculate volatility-based fee
     * @dev Fee increases when price moves away from reference bin
     * @param feeParams Fee parameters
     * @param activeBinId Current active bin
     * @param targetBinId Target bin after swap
     * @return volatilityFeeBps Volatility fee in basis points
     */
    function getVolatilityFee(
        ILBPairTypes.FeeParameters memory feeParams,
        uint24 activeBinId,
        uint24 targetBinId
    ) internal pure returns (uint256 volatilityFeeBps) {
        // Calculate distance from reference bin
        uint24 referenceBin = feeParams.volatilityReference;

        // Distance current position is from reference
        uint256 currentDistance = activeBinId > referenceBin
            ? activeBinId - referenceBin
            : referenceBin - activeBinId;

        // Distance after swap
        uint256 targetDistance = targetBinId > referenceBin
            ? targetBinId - referenceBin
            : referenceBin - targetBinId;

        // Use larger distance (more volatile = higher fee)
        uint256 maxDistance = currentDistance > targetDistance ? currentDistance : targetDistance;

        // Calculate volatility fee: increases with distance from reference
        // volatilityFee = min(maxDistance * reductionFactor, maxVolatilityFee)
        volatilityFeeBps = (maxDistance * feeParams.reductionFactor) / BASIS_POINT_MAX;

        // Cap at maximum volatility fee
        if (volatilityFeeBps > feeParams.maxVolatilityFee) {
            volatilityFeeBps = feeParams.maxVolatilityFee;
        }
    }

    /**
     * @notice Apply time-based fee adjustment for stock trading
     * @dev Lower fees during market hours (high volume), higher during off-hours (low liquidity)
     * @param baseFee Base fee before adjustment
     * @return adjustedFee Fee after time adjustment
     */
    function applyTimeAdjustment(uint256 baseFee) internal view returns (uint256 adjustedFee) {
        // Get current hour and minute (UTC)
        uint256 timestamp = block.timestamp;
        uint256 secondsInDay = timestamp % 86400; // Seconds since midnight UTC
        uint256 hour = secondsInDay / 3600;
        uint256 minute = (secondsInDay % 3600) / 60;

        // Check if we're in market hours (13:30 - 20:00 UTC = 9:30am - 4:00pm ET)
        bool isMarketHours = false;

        if (hour > MARKET_OPEN_HOUR && hour < MARKET_CLOSE_HOUR) {
            isMarketHours = true;
        } else if (hour == MARKET_OPEN_HOUR && minute >= MARKET_OPEN_MINUTE) {
            isMarketHours = true;
        } else if (hour == MARKET_CLOSE_HOUR && minute == 0) {
            isMarketHours = true;
        }

        if (isMarketHours) {
            // Market hours: normal fee
            adjustedFee = baseFee;
        } else {
            // Off-hours: 1.5x fee (lower liquidity)
            adjustedFee = (baseFee * OFF_HOURS_MULTIPLIER) / BASIS_POINT_MAX;
        }
    }

    /**
     * @notice Calculate fee amount from input amount
     * @param amountIn Input amount
     * @param feeBps Fee in basis points
     * @return feeAmount Fee amount to collect
     * @return amountAfterFee Amount after deducting fee
     */
    function calculateFee(
        uint256 amountIn,
        uint256 feeBps
    ) internal pure returns (uint256 feeAmount, uint256 amountAfterFee) {
        feeAmount = (amountIn * feeBps) / BASIS_POINT_MAX;
        amountAfterFee = amountIn - feeAmount;
    }

    /**
     * @notice Split fee between LPs and protocol
     * @param totalFee Total fee collected
     * @param protocolShare Protocol's share in basis points
     * @return lpFee Fee for LPs
     * @return protocolFee Fee for protocol
     */
    function splitFee(
        uint256 totalFee,
        uint16 protocolShare
    ) internal pure returns (uint256 lpFee, uint256 protocolFee) {
        protocolFee = (totalFee * protocolShare) / BASIS_POINT_MAX;
        lpFee = totalFee - protocolFee;
    }

    /**
     * @notice Validate fee parameters
     * @param feeParams Fee parameters to validate
     */
    function validateFeeParameters(
        ILBPairTypes.FeeParameters memory feeParams
    ) internal pure {
        // Base fee must be reasonable
        if (feeParams.baseFee > MAX_TOTAL_FEE) {
            revert FeeHelper__FeeTooHigh();
        }

        // Max volatility fee must be reasonable
        if (feeParams.maxVolatilityFee > MAX_TOTAL_FEE) {
            revert FeeHelper__FeeTooHigh();
        }

        // Protocol share must be less than 100%
        if (feeParams.protocolShare > BASIS_POINT_MAX) {
            revert FeeHelper__InvalidFeeParameters();
        }

        // Total potential fee (base + max volatility) should not exceed reasonable limits
        if (feeParams.baseFee + feeParams.maxVolatilityFee > MAX_TOTAL_FEE * 2) {
            revert FeeHelper__FeeTooHigh();
        }
    }

    /**
     * @notice Get default fee parameters for stock pairs
     * @return Default fee parameters optimized for stock trading
     */
    function getDefaultStockFeeParameters()
        internal
        pure
        returns (ILBPairTypes.FeeParameters memory)
    {
        return
            ILBPairTypes.FeeParameters({
                baseFee: 30, // 0.3% base fee
                protocolShare: 500, // 5% of fees go to protocol
                maxVolatilityFee: 100, // Max 1% additional volatility fee
                volatilityReference: 8_388_608, // Initial bin (middle of range)
                filterPeriod: 30, // 30 second smoothing
                decayPeriod: 600, // 10 minute decay
                reductionFactor: 5000 // 50% reduction factor
            });
    }

    /**
     * @notice Update volatility reference bin (called periodically)
     * @dev Slowly moves reference toward current active bin
     * @param currentReference Current reference bin
     * @param activeBinId Current active bin
     * @param filterPeriod Smoothing period
     * @return newReference Updated reference bin
     */
    function updateVolatilityReference(
        uint24 currentReference,
        uint24 activeBinId,
        uint16 filterPeriod
    ) internal pure returns (uint24 newReference) {
        if (filterPeriod == 0) {
            return activeBinId; // No smoothing
        }

        // Exponential moving average toward active bin
        // newRef = currentRef + (activeId - currentRef) / filterPeriod
        if (activeBinId > currentReference) {
            uint24 delta = activeBinId - currentReference;
            uint24 adjustment = uint24(delta / filterPeriod);
            newReference = currentReference + (adjustment > 0 ? adjustment : 1);
        } else if (activeBinId < currentReference) {
            uint24 delta = currentReference - activeBinId;
            uint24 adjustment = uint24(delta / filterPeriod);
            newReference = currentReference - (adjustment > 0 ? adjustment : 1);
        } else {
            newReference = currentReference;
        }
    }

    /**
     * @notice Calculate accumulated fees per share for a bin
     * @dev Used for auto-compounding fee distribution
     * @param currentFeeGrowth Current fee growth per share
     * @param feesCollected Fees collected this swap
     * @param totalShares Total shares in bin
     * @return newFeeGrowth Updated fee growth per share
     */
    function accumulateFees(
        uint128 currentFeeGrowth,
        uint256 feesCollected,
        uint128 totalShares
    ) internal pure returns (uint128 newFeeGrowth) {
        if (totalShares == 0) return currentFeeGrowth;

        // feeGrowth += feesCollected / totalShares (scaled by 1e18)
        uint256 feePerShare = (feesCollected * 1e18) / totalShares;

        // Add to current growth (with overflow protection)
        unchecked {
            newFeeGrowth = currentFeeGrowth + uint128(feePerShare);
        }
    }
}
