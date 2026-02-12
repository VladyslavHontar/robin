// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title BitMath
 * @notice Library for bit manipulation operations
 * @dev Used for efficient bitmap traversal in DLMM bin finding
 *
 * Provides functions to find the most/least significant bits in uint256 values,
 * which is crucial for quickly locating non-empty bins in sparse bin arrays.
 */
library BitMath {
    /**
     * @notice Find the index of the most significant bit
     * @dev Returns the 0-indexed position of the highest set bit
     * @param x The value to analyze (must be non-zero)
     * @return msb The index of the most significant bit (0-255)
     *
     * Example: mostSignificantBit(8) = 3 (binary: 1000)
     * Example: mostSignificantBit(255) = 7 (binary: 11111111)
     */
    function mostSignificantBit(uint256 x) internal pure returns (uint8 msb) {
        require(x > 0, "BitMath: zero has no msb");

        // Binary search approach for finding MSB
        // Divide and conquer: check upper half, then narrow down

        if (x >= 0x100000000000000000000000000000000) {
            x >>= 128;
            msb = 128;
        }
        if (x >= 0x10000000000000000) {
            x >>= 64;
            msb |= 64;
        }
        if (x >= 0x100000000) {
            x >>= 32;
            msb |= 32;
        }
        if (x >= 0x10000) {
            x >>= 16;
            msb |= 16;
        }
        if (x >= 0x100) {
            x >>= 8;
            msb |= 8;
        }
        if (x >= 0x10) {
            x >>= 4;
            msb |= 4;
        }
        if (x >= 0x4) {
            x >>= 2;
            msb |= 2;
        }
        if (x >= 0x2) {
            msb |= 1;
        }
    }

    /**
     * @notice Find the index of the least significant bit
     * @dev Returns the 0-indexed position of the lowest set bit
     * @param x The value to analyze (must be non-zero)
     * @return lsb The index of the least significant bit (0-255)
     *
     * Example: leastSignificantBit(8) = 3 (binary: 1000)
     * Example: leastSignificantBit(6) = 1 (binary: 110)
     */
    function leastSignificantBit(uint256 x) internal pure returns (uint8 lsb) {
        require(x > 0, "BitMath: zero has no lsb");

        // Isolate the least significant bit using x & -x
        // Then find its position using mostSignificantBit
        lsb = mostSignificantBit(x & (~x + 1));
    }

    /**
     * @notice Find the closest bit to the left (lower index) that is set
     * @dev Used for finding the next non-empty bin when swapping down in price
     * @param x The bitmap to search
     * @param bit The starting bit position
     * @param shouldInclude Whether to include the starting bit in the search
     * @return closestBit The position of the closest set bit to the left
     * @return found Whether a set bit was found
     *
     * Example: closestBitLeft(0b1010, 3, false) = (3, true) if bit 3 is set
     */
    function closestBitLeft(
        uint256 x,
        uint8 bit,
        bool shouldInclude
    ) internal pure returns (uint8 closestBit, bool found) {
        if (!shouldInclude) {
            // Don't include the current bit, mask it out
            if (bit > 0) {
                x = x & ((1 << bit) - 1); // Keep only bits 0 to bit-1
            } else {
                return (0, false); // No bits to the left of bit 0
            }
        } else {
            // Include current bit and all to the left
            x = x & ((1 << (bit + 1)) - 1); // Keep bits 0 to bit
        }

        if (x == 0) {
            return (0, false);
        }

        closestBit = mostSignificantBit(x);
        found = true;
    }

    /**
     * @notice Find the closest bit to the right (higher index) that is set
     * @dev Used for finding the next non-empty bin when swapping up in price
     * @param x The bitmap to search
     * @param bit The starting bit position
     * @param shouldInclude Whether to include the starting bit in the search
     * @return closestBit The position of the closest set bit to the right
     * @return found Whether a set bit was found
     *
     * Example: closestBitRight(0b1010, 0, false) = (1, true)
     */
    function closestBitRight(
        uint256 x,
        uint8 bit,
        bool shouldInclude
    ) internal pure returns (uint8 closestBit, bool found) {
        if (!shouldInclude) {
            // Don't include the current bit, mask out everything up to and including it
            if (bit < 255) {
                x = x & ~((1 << (bit + 1)) - 1); // Keep only bits above bit
            } else {
                return (0, false); // No bits to the right of bit 255
            }
        } else {
            // Include current bit and all to the right
            x = x & ~((1 << bit) - 1); // Keep bits from bit upward
        }

        if (x == 0) {
            return (0, false);
        }

        closestBit = leastSignificantBit(x);
        found = true;
    }

    /**
     * @notice Set a bit in a bitmap
     * @param bitmap The original bitmap
     * @param bit The bit position to set (0-255)
     * @return The updated bitmap with the bit set
     */
    function setBit(uint256 bitmap, uint8 bit) internal pure returns (uint256) {
        return bitmap | (1 << bit);
    }

    /**
     * @notice Clear a bit in a bitmap
     * @param bitmap The original bitmap
     * @param bit The bit position to clear (0-255)
     * @return The updated bitmap with the bit cleared
     */
    function clearBit(uint256 bitmap, uint8 bit) internal pure returns (uint256) {
        return bitmap & ~(1 << bit);
    }

    /**
     * @notice Check if a bit is set
     * @param bitmap The bitmap to check
     * @param bit The bit position to check (0-255)
     * @return Whether the bit is set
     */
    function isBitSet(uint256 bitmap, uint8 bit) internal pure returns (bool) {
        return (bitmap & (1 << bit)) != 0;
    }

    /**
     * @notice Count the number of set bits in a bitmap
     * @dev Uses Brian Kernighan's algorithm
     * @param x The bitmap to count
     * @return count The number of set bits
     */
    function popCount(uint256 x) internal pure returns (uint256 count) {
        // Brian Kernighan's algorithm: repeatedly clear the lowest set bit
        while (x != 0) {
            x &= x - 1; // Clear the lowest set bit
            count++;
        }
    }

    /**
     * @notice Create a bitmask with all bits set from bit `from` to bit `to` (inclusive)
     * @param from The starting bit position
     * @param to The ending bit position
     * @return mask The bitmask
     */
    function createBitMask(uint8 from, uint8 to) internal pure returns (uint256 mask) {
        require(from <= to, "BitMath: invalid range");
        require(to < 256, "BitMath: bit overflow");

        if (to == 255) {
            // Special case: avoid overflow when creating mask for bit 255
            mask = type(uint256).max << from;
        } else {
            mask = ((1 << (to + 1)) - 1) & ~((1 << from) - 1);
        }
    }
}
