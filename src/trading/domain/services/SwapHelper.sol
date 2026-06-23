// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILBPairTypes} from "../kernel/ILBPairTypes.sol";
import {SafeCast} from "./SafeCast.sol";
import {BinMath} from "./BinMath.sol";

library SwapHelper {
    uint24 internal constant MAX_BINS_PER_SWAP = 100;

    error SwapHelper__InvalidReserves();

    /// @param price Bin price scaled by BinMath.SCALE (units of Y per 1 unit of X).
    function getAmountOutSingleBin(
        ILBPairTypes.BinState memory bin,
        uint256 amountIn,
        bool swapForY,
        uint256 price
    ) internal pure returns (uint256 amountOut, uint256 amountInConsumed) {
        uint256 reserveOut = swapForY ? uint256(bin.reserveY) : uint256(bin.reserveX);

        if (reserveOut == 0) {
            revert SwapHelper__InvalidReserves();
        }

        // Convert the input amount to output through the bin price.
        uint256 fullOut = swapForY
            ? BinMath._mulDivDown(amountIn, price, BinMath.SCALE)
            : BinMath._mulDivDown(amountIn, BinMath.SCALE, price);

        if (fullOut <= reserveOut) {
            amountOut = fullOut;
            amountInConsumed = amountIn;
        } else {
            amountOut = reserveOut;
            // Input required to drain exactly `reserveOut` of the output token.
            amountInConsumed = swapForY
                ? BinMath._mulDivDown(reserveOut, BinMath.SCALE, price)
                : BinMath._mulDivDown(reserveOut, price, BinMath.SCALE);
        }
    }

    function updateBinReserves(
        ILBPairTypes.BinState memory bin,
        uint256 amountIn,
        uint256 amountOut,
        bool swapForY
    ) internal pure {
        if (swapForY) {
            bin.reserveX += SafeCast.toUint112(amountIn);
            bin.reserveY -= SafeCast.toUint112(amountOut);
        } else {
            bin.reserveY += SafeCast.toUint112(amountIn);
            bin.reserveX -= SafeCast.toUint112(amountOut);
        }
    }

    function calculatePriceImpact(
        uint24 startBinId,
        uint24 endBinId,
        uint16 binStep
    ) internal pure returns (uint256 impactBps) {
        if (startBinId == endBinId) return 0;

        uint24 binsMoved = startBinId > endBinId
            ? startBinId - endBinId
            : endBinId - startBinId;

        impactBps = uint256(binsMoved) * uint256(binStep);
    }
}
