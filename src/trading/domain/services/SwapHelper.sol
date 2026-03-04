// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILBPairTypes} from "../kernel/ILBPairTypes.sol";
import {SafeCast} from "./SafeCast.sol";

library SwapHelper {
    uint24 internal constant MAX_BINS_PER_SWAP = 100;

    error SwapHelper__InvalidReserves();

    function getAmountOutSingleBin(
        ILBPairTypes.BinState memory bin,
        uint256 amountIn,
        bool swapForY
    ) internal pure returns (uint256 amountOut, uint256 amountInConsumed) {
        uint256 reserveOut = swapForY ? uint256(bin.reserveY) : uint256(bin.reserveX);

        if (reserveOut == 0) {
            revert SwapHelper__InvalidReserves();
        }

        if (amountIn <= reserveOut) {
            amountOut = amountIn;
            amountInConsumed = amountIn;
        } else {
            amountOut = reserveOut;
            amountInConsumed = reserveOut;
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
