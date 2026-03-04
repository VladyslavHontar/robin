// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILBPairTypes} from "../kernel/ILBPairTypes.sol";

library FeeHelper {
    uint256 internal constant MAX_TOTAL_FEE = 1000;

    uint256 internal constant BASIS_POINT_MAX = 10_000;

    uint256 internal constant MARKET_OPEN_HOUR = 13;
    uint256 internal constant MARKET_OPEN_MINUTE = 30;

    uint256 internal constant MARKET_CLOSE_HOUR = 20;

    uint256 internal constant OFF_HOURS_MULTIPLIER = 15_000;

    error FeeHelper__InvalidFeeParameters();
    error FeeHelper__FeeTooHigh();

    function getTotalFee(
        ILBPairTypes.FeeParameters memory feeParams,
        uint24 activeBinId,
        uint24 targetBinId
    ) internal view returns (uint256 totalFeeBps) {
        totalFeeBps = feeParams.baseFee;

        if (activeBinId != targetBinId) {
            uint256 volatilityFee = getVolatilityFee(feeParams, activeBinId, targetBinId);
            totalFeeBps += volatilityFee;
        }

        totalFeeBps = applyTimeAdjustment(totalFeeBps);

        if (totalFeeBps > MAX_TOTAL_FEE) {
            totalFeeBps = MAX_TOTAL_FEE;
        }
    }

    function getTotalFee(
        ILBPairTypes.FeeParameters memory feeParams,
        uint24 activeBinId,
        uint24 targetBinId,
        uint256 oracleDeviationFeeBps
    ) internal view returns (uint256 totalFeeBps) {
        totalFeeBps = feeParams.baseFee;

        if (activeBinId != targetBinId) {
            uint256 volatilityFee = getVolatilityFee(feeParams, activeBinId, targetBinId);
            totalFeeBps += volatilityFee;
        }

        totalFeeBps += oracleDeviationFeeBps;

        totalFeeBps = applyTimeAdjustment(totalFeeBps);

        if (totalFeeBps > MAX_TOTAL_FEE) {
            totalFeeBps = MAX_TOTAL_FEE;
        }
    }

    function getOracleDeviationFee(
        uint24 activeBinId,
        uint24 oracleBinId,
        ILBPairTypes.OracleDeviationParams memory params
    ) internal pure returns (uint256 feeBps) {
        uint256 deviation = activeBinId > oracleBinId
            ? uint256(activeBinId - oracleBinId)
            : uint256(oracleBinId - activeBinId);

        if (deviation <= params.deadzoneBins) {
            return 0;
        }

        uint256 binsInTier1;
        if (deviation <= params.tier1MaxBins) {
            binsInTier1 = deviation - params.deadzoneBins;
            feeBps = binsInTier1 * params.tier1RatePerBin;
            return feeBps > params.maxDeviationFee ? params.maxDeviationFee : feeBps;
        }

        binsInTier1 = uint256(params.tier1MaxBins) - uint256(params.deadzoneBins);
        uint256 tier1Fee = binsInTier1 * params.tier1RatePerBin;

        if (deviation <= params.tier2MaxBins) {
            uint256 binsInTier2 = deviation - params.tier1MaxBins;
            feeBps = tier1Fee + binsInTier2 * params.tier2RatePerBin;
            return feeBps > params.maxDeviationFee ? params.maxDeviationFee : feeBps;
        }

        return params.maxDeviationFee;
    }

    function getVolatilityFee(
        ILBPairTypes.FeeParameters memory feeParams,
        uint24 activeBinId,
        uint24 targetBinId
    ) internal pure returns (uint256 volatilityFeeBps) {
        uint24 referenceBin = feeParams.volatilityReference;

        uint256 currentDistance = activeBinId > referenceBin
            ? activeBinId - referenceBin
            : referenceBin - activeBinId;

        uint256 targetDistance = targetBinId > referenceBin
            ? targetBinId - referenceBin
            : referenceBin - targetBinId;

        uint256 maxDistance = currentDistance > targetDistance ? currentDistance : targetDistance;

        volatilityFeeBps = (maxDistance * feeParams.reductionFactor) / BASIS_POINT_MAX;

        if (volatilityFeeBps > feeParams.maxVolatilityFee) {
            volatilityFeeBps = feeParams.maxVolatilityFee;
        }
    }

    function applyTimeAdjustment(uint256 baseFee) internal view returns (uint256 adjustedFee) {
        uint256 timestamp = block.timestamp;
        uint256 secondsInDay = timestamp % 86400;
        uint256 hour = secondsInDay / 3600;
        uint256 minute = (secondsInDay % 3600) / 60;

        bool isMarketHours = false;

        if (hour > MARKET_OPEN_HOUR && hour < MARKET_CLOSE_HOUR) {
            isMarketHours = true;
        } else if (hour == MARKET_OPEN_HOUR && minute >= MARKET_OPEN_MINUTE) {
            isMarketHours = true;
        } else if (hour == MARKET_CLOSE_HOUR && minute == 0) {
            isMarketHours = true;
        }

        if (isMarketHours) {
            adjustedFee = baseFee;
        } else {
            adjustedFee = (baseFee * OFF_HOURS_MULTIPLIER) / BASIS_POINT_MAX;
        }
    }

    function calculateFee(
        uint256 amountIn,
        uint256 feeBps
    ) internal pure returns (uint256 feeAmount, uint256 amountAfterFee) {
        feeAmount = (amountIn * feeBps) / BASIS_POINT_MAX;
        amountAfterFee = amountIn - feeAmount;
    }

    function splitFee(
        uint256 totalFee,
        uint16 protocolShare
    ) internal pure returns (uint256 lpFee, uint256 protocolFee) {
        protocolFee = (totalFee * protocolShare) / BASIS_POINT_MAX;
        lpFee = totalFee - protocolFee;
    }

    function validateFeeParameters(
        ILBPairTypes.FeeParameters memory feeParams
    ) internal pure {
        if (feeParams.baseFee > MAX_TOTAL_FEE) {
            revert FeeHelper__FeeTooHigh();
        }

        if (feeParams.maxVolatilityFee > MAX_TOTAL_FEE) {
            revert FeeHelper__FeeTooHigh();
        }

        if (feeParams.protocolShare > BASIS_POINT_MAX) {
            revert FeeHelper__InvalidFeeParameters();
        }

        if (feeParams.baseFee + feeParams.maxVolatilityFee > MAX_TOTAL_FEE * 2) {
            revert FeeHelper__FeeTooHigh();
        }
    }

    function getDefaultStockFeeParameters()
        internal
        pure
        returns (ILBPairTypes.FeeParameters memory)
    {
        return
            ILBPairTypes.FeeParameters({
                baseFee: 30,
                protocolShare: 500,
                maxVolatilityFee: 100,
                volatilityReference: 8_388_608,
                filterPeriod: 30,
                decayPeriod: 600,
                reductionFactor: 5000
            });
    }

    function accumulateFees(
        uint128 currentFeeGrowth,
        uint256 feesCollected,
        uint128 totalShares
    ) internal pure returns (uint128 newFeeGrowth) {
        if (totalShares == 0) return currentFeeGrowth;

        uint256 feePerShare = (feesCollected * 1e18) / totalShares;

        if (feePerShare > type(uint128).max) feePerShare = type(uint128).max;

        uint256 newGrowth = uint256(currentFeeGrowth) + feePerShare;
        newFeeGrowth = newGrowth > type(uint128).max ? type(uint128).max : uint128(newGrowth);
    }
}
