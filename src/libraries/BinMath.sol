// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title BinMath
 * @notice Mathematical library for DLMM bin price calculations
 * @dev Handles conversions between bin IDs and prices using exponential formulas
 *
 * Core formula: price(binId) = (1 + binStep/10000)^(binId - INITIAL_BIN_ID)
 *
 * Price precision: 128.128 fixed point (uint256 with 128 decimal bits)
 */
library BinMath {
    /// @notice Initial bin ID at the center of the 24-bit range
    /// @dev This represents price = 1.0 (scaled by SCALE)
    uint24 internal constant INITIAL_BIN_ID = 8_388_608; // 2^23

    /// @notice Scale for price calculations (2^128)
    /// @dev Prices are represented as uint256 with 128 bits of precision
    uint256 internal constant SCALE = 0x100000000000000000000000000000000; // 2^128

    /// @notice Maximum bin step (10000 bp = 100%)
    uint16 internal constant MAX_BIN_STEP = 10_000;

    /// @notice Basis points divisor
    uint256 internal constant BASIS_POINT_MAX = 10_000;

    /**
     * @notice Get price from bin ID
     * @dev price = (1 + binStep/10000)^(binId - INITIAL_BIN_ID)
     * @param binId The bin ID (24-bit value)
     * @param binStep The bin step in basis points (1-10000)
     * @return price The price scaled by 2^128
     */
    function getPriceFromId(uint24 binId, uint16 binStep) internal pure returns (uint256 price) {
        require(binStep > 0 && binStep <= MAX_BIN_STEP, "BinMath: invalid bin step");

        // Handle initial bin specially (price = 1.0)
        if (binId == INITIAL_BIN_ID) {
            return SCALE;
        }

        // Calculate exponent: (binId - INITIAL_BIN_ID)
        // Can be positive or negative
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

        // For positive exponents: price = (1 + binStep/10000)^exponent
        // For negative exponents: price = 1 / (1 + binStep/10000)^exponent = (1 - binStep/(10000+binStep))^exponent
        // To avoid SCALE^2 overflow, we compute the inverse base directly for negative exponents

        if (!isNegative) {
            // Positive exponent: base = (1 + binStep/10000) scaled by SCALE
            uint256 base = (SCALE * (BASIS_POINT_MAX + binStep)) / BASIS_POINT_MAX;
            price = _pow(base, exponent);
        } else {
            // Negative exponent: use inverse base = 1/base to avoid overflow
            // inverse_base = SCALE / base = SCALE * BASIS_POINT_MAX / (BASIS_POINT_MAX + binStep)
            // Multiply SCALE first, then divide to maintain precision
            uint256 inverseBase = (SCALE * BASIS_POINT_MAX) / (BASIS_POINT_MAX + binStep);
            price = _pow(inverseBase, exponent);
        }
    }

    /**
     * @notice Get bin ID from price
     * @dev Inverse of getPriceFromId: binId = log_{1+binStep/10000}(price) + INITIAL_BIN_ID
     * @param price The price scaled by 2^128
     * @param binStep The bin step in basis points (1-10000)
     * @return binId The bin ID (24-bit value)
     */
    function getIdFromPrice(uint256 price, uint16 binStep) internal pure returns (uint24 binId) {
        require(binStep > 0 && binStep <= MAX_BIN_STEP, "BinMath: invalid bin step");
        require(price > 0, "BinMath: price must be positive");

        if (price == SCALE) {
            return INITIAL_BIN_ID;
        }

        // Bound the search to prevent overflow in _pow.
        // Max representable exponent: (1 + binStep/10000)^n * SCALE < 2^256
        // → n < 128 * ln(2) / ln(1 + binStep/10000) ≈ 800000 / binStep
        uint24 maxDelta = uint24(800_000 / uint256(binStep));
        if (maxDelta > INITIAL_BIN_ID) maxDelta = INITIAL_BIN_ID; // Prevent underflow

        bool searchUp = price > SCALE;
        uint24 low = searchUp ? INITIAL_BIN_ID : (INITIAL_BIN_ID > maxDelta ? INITIAL_BIN_ID - maxDelta : 0);
        uint24 high = searchUp ? INITIAL_BIN_ID + maxDelta : INITIAL_BIN_ID;

        // Binary search for the correct bin
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

        // Return the bin containing this price (round down)
        binId = searchUp ? low - 1 : low;
    }

    /**
     * @notice Get the base price of a bin (lower bound)
     * @param binId The bin ID
     * @param binStep The bin step in basis points
     * @return The lower price bound scaled by 2^128
     */
    function getBasePriceOfBin(uint24 binId, uint16 binStep) internal pure returns (uint256) {
        return getPriceFromId(binId, binStep);
    }

    /**
     * @notice Get the upper price of a bin
     * @param binId The bin ID
     * @param binStep The bin step in basis points
     * @return The upper price bound scaled by 2^128
     */
    function getUpperPriceOfBin(uint24 binId, uint16 binStep) internal pure returns (uint256) {
        return getPriceFromId(binId + 1, binStep);
    }

    /**
     * @notice Check if a price is within a bin's range
     * @param price The price to check
     * @param binId The bin ID
     * @param binStep The bin step in basis points
     * @return Whether the price is within the bin
     */
    function isPriceInBin(uint256 price, uint24 binId, uint16 binStep) internal pure returns (bool) {
        uint256 lowerBound = getBasePriceOfBin(binId, binStep);
        uint256 upperBound = getUpperPriceOfBin(binId, binStep);
        return price >= lowerBound && price < upperBound;
    }

    /**
     * @notice Get price ratio between two bins
     * @param binId1 First bin ID
     * @param binId2 Second bin ID
     * @param binStep The bin step in basis points
     * @return ratio The price ratio (price1/price2) scaled by 2^128
     */
    function getPriceRatio(
        uint24 binId1,
        uint24 binId2,
        uint16 binStep
    ) internal pure returns (uint256 ratio) {
        uint256 price1 = getPriceFromId(binId1, binStep);
        uint256 price2 = getPriceFromId(binId2, binStep);
        ratio = (price1 * SCALE) / price2;
    }

    /**
     * @notice Binary exponentiation for fixed-point numbers
     * @dev Calculates base^exp where base is scaled by 2^128
     *      Uses 512-bit intermediate multiplication to avoid overflow
     * @param base The base value (scaled by 2^128)
     * @param exp The exponent (unscaled integer)
     * @return result base^exp (scaled by 2^128)
     */
    function _pow(uint256 base, uint256 exp) private pure returns (uint256 result) {
        if (exp == 0) {
            return SCALE; // Any number^0 = 1
        }
        if (exp == 1) {
            return base;
        }

        result = SCALE; // Start with 1.0 scaled

        // Binary exponentiation
        while (exp > 0) {
            if (exp & 1 == 1) {
                result = _mulDivDown(result, base, SCALE);
            }
            base = _mulDivDown(base, base, SCALE);
            exp >>= 1;
        }
    }

    /**
     * @notice Full-precision multiply then divide: (x * y) / d without overflow
     * @dev Uses 512-bit intermediate multiplication via assembly
     * @param x First multiplicand
     * @param y Second multiplicand
     * @param d Divisor
     * @return result (x * y) / d rounded down
     */
    function _mulDivDown(uint256 x, uint256 y, uint256 d) private pure returns (uint256 result) {
        // 512-bit multiply [prod1 prod0] = x * y
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(x, y, not(0))
            prod0 := mul(x, y)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        // No overflow — simple case
        if (prod1 == 0) {
            return prod0 / d;
        }

        // Overflow: need full 512-bit division
        require(d > prod1, "BinMath: mulDiv overflow");

        uint256 remainder;
        assembly {
            remainder := mulmod(x, y, d)
        }
        assembly {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        // Factor powers of two out of denominator
        uint256 twos = d & (~d + 1);
        assembly {
            d := div(d, twos)
            prod0 := div(prod0, twos)
            twos := add(div(sub(0, twos), twos), 1)
        }
        prod0 |= prod1 * twos;

        // Compute modular inverse of d using Newton's method
        uint256 inverse = (3 * d) ^ 2;
        inverse *= 2 - d * inverse;
        inverse *= 2 - d * inverse;
        inverse *= 2 - d * inverse;
        inverse *= 2 - d * inverse;
        inverse *= 2 - d * inverse;

        result = prod0 * inverse;
    }

    /**
     * @notice Convert price from human-readable format to scaled format
     * @dev Useful for testing and initialization
     * @param humanPrice Price in human-readable format (e.g., 150 for $150)
     * @param decimals Number of decimal places (e.g., 18 for ETH, 6 for USDC)
     * @return Scaled price (2^128 format)
     */
    function fromHumanPrice(uint256 humanPrice, uint8 decimals) internal pure returns (uint256) {
        return (humanPrice * SCALE) / (10 ** decimals);
    }

    /**
     * @notice Convert price from scaled format to human-readable format
     * @dev Useful for display and testing
     * @param scaledPrice Price in 2^128 scaled format
     * @param decimals Number of decimal places to display
     * @return Human-readable price
     */
    function toHumanPrice(uint256 scaledPrice, uint8 decimals) internal pure returns (uint256) {
        return (scaledPrice * (10 ** decimals)) / SCALE;
    }
}
