// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

library BinMath {
    uint24 internal constant INITIAL_BIN_ID = 8_388_608;

    uint256 internal constant SCALE = 0x100000000000000000000000000000000;

    uint16 internal constant MAX_BIN_STEP = 10_000;

    uint256 internal constant BASIS_POINT_MAX = 10_000;

    function getPriceFromId(uint24 binId, uint16 binStep) internal pure returns (uint256 price) {
        require(binStep > 0 && binStep <= MAX_BIN_STEP, "BinMath: invalid bin step");

        if (binId == INITIAL_BIN_ID) {
            return SCALE;
        }

        uint256 exponent;
        bool isNegative;

        unchecked {
            if (binId > INITIAL_BIN_ID) {
                exponent = uint256(binId - INITIAL_BIN_ID);
                isNegative = false;
            } else {
                exponent = uint256(INITIAL_BIN_ID - binId);
                isNegative = true;
            }
        }

        if (!isNegative) {
            uint256 base = (SCALE * (BASIS_POINT_MAX + binStep)) / BASIS_POINT_MAX;
            price = _pow(base, exponent);
        } else {
            uint256 inverseBase = (SCALE * BASIS_POINT_MAX) / (BASIS_POINT_MAX + binStep);
            price = _pow(inverseBase, exponent);
        }
    }

    function getIdFromPrice(uint256 price, uint16 binStep) internal pure returns (uint24 binId) {
        require(binStep > 0 && binStep <= MAX_BIN_STEP, "BinMath: invalid bin step");
        require(price > 0, "BinMath: price must be positive");

        if (price == SCALE) {
            return INITIAL_BIN_ID;
        }

        uint24 maxDelta = uint24(440_000 / uint256(binStep));
        if (maxDelta > INITIAL_BIN_ID) maxDelta = INITIAL_BIN_ID;

        bool searchUp = price > SCALE;
        uint24 low = searchUp ? INITIAL_BIN_ID : (INITIAL_BIN_ID > maxDelta ? INITIAL_BIN_ID - maxDelta : 0);
        uint24 high = searchUp ? INITIAL_BIN_ID + maxDelta : INITIAL_BIN_ID;

        while (low < high) {
            uint24 mid = uint24((uint256(low) + uint256(high)) / 2);
            uint256 midPrice = getPriceFromId(mid, binStep);

            if (midPrice == price) {
                return mid;
            } else if (midPrice < price) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        binId = searchUp ? low - 1 : low;
    }

    function getBasePriceOfBin(uint24 binId, uint16 binStep) internal pure returns (uint256) {
        return getPriceFromId(binId, binStep);
    }

    function getUpperPriceOfBin(uint24 binId, uint16 binStep) internal pure returns (uint256) {
        return getPriceFromId(binId + 1, binStep);
    }

    function isPriceInBin(uint256 price, uint24 binId, uint16 binStep) internal pure returns (bool) {
        uint256 lowerBound = getBasePriceOfBin(binId, binStep);
        uint256 upperBound = getUpperPriceOfBin(binId, binStep);
        return price >= lowerBound && price < upperBound;
    }

    function getPriceRatio(
        uint24 binId1,
        uint24 binId2,
        uint16 binStep
    ) internal pure returns (uint256 ratio) {
        uint256 price1 = getPriceFromId(binId1, binStep);
        uint256 price2 = getPriceFromId(binId2, binStep);
        ratio = _mulDivDown(price1, SCALE, price2);
    }

    function _pow(uint256 base, uint256 exp) private pure returns (uint256 result) {
        if (exp == 0) {
            return SCALE;
        }
        if (exp == 1) {
            return base;
        }

        result = SCALE;

        while (exp > 0) {
            if (exp & 1 == 1) {
                result = _mulDivDown(result, base, SCALE);
            }
            exp >>= 1;
            if (exp > 0) {
                base = _mulDivDown(base, base, SCALE);
            }
        }
    }

    function _mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(x, y, not(0))
            prod0 := mul(x, y)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        if (prod1 == 0) {
            return prod0 / d;
        }

        require(d > prod1, "BinMath: mulDiv overflow");

        uint256 remainder;
        assembly {
            remainder := mulmod(x, y, d)
        }
        assembly {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        unchecked {
            uint256 twos = d & (~d + 1);
            assembly {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inverse = (3 * d) ^ 2;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;

            result = prod0 * inverse;
        }
    }

    function fromHumanPrice(uint256 humanPrice, uint8 decimals) internal pure returns (uint256) {
        return (humanPrice * SCALE) / (10 ** decimals);
    }

    function toHumanPrice(uint256 scaledPrice, uint8 decimals) internal pure returns (uint256) {
        return (scaledPrice * (10 ** decimals)) / SCALE;
    }
}
