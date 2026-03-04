// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

library BitMath {
    function mostSignificantBit(uint256 x) internal pure returns (uint8 msb) {
        require(x > 0, "BitMath: zero has no msb");

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

    function leastSignificantBit(uint256 x) internal pure returns (uint8 lsb) {
        require(x > 0, "BitMath: zero has no lsb");

        lsb = mostSignificantBit(x & (~x + 1));
    }

    function closestBitLeft(
        uint256 x,
        uint8 bit,
        bool shouldInclude
    ) internal pure returns (uint8 closestBit, bool found) {
        if (!shouldInclude) {
            if (bit > 0) {
                x = x & ((1 << bit) - 1);
            } else {
                return (0, false);
            }
        } else {
            x = x & ((1 << (bit + 1)) - 1);
        }

        if (x == 0) {
            return (0, false);
        }

        closestBit = mostSignificantBit(x);
        found = true;
    }

    function closestBitRight(
        uint256 x,
        uint8 bit,
        bool shouldInclude
    ) internal pure returns (uint8 closestBit, bool found) {
        if (!shouldInclude) {
            if (bit < 255) {
                x = x & ~((1 << (bit + 1)) - 1);
            } else {
                return (0, false);
            }
        } else {
            x = x & ~((1 << bit) - 1);
        }

        if (x == 0) {
            return (0, false);
        }

        closestBit = leastSignificantBit(x);
        found = true;
    }

    function setBit(uint256 bitmap, uint8 bit) internal pure returns (uint256) {
        return bitmap | (1 << bit);
    }

    function clearBit(uint256 bitmap, uint8 bit) internal pure returns (uint256) {
        return bitmap & ~(1 << bit);
    }

    function isBitSet(uint256 bitmap, uint8 bit) internal pure returns (bool) {
        return (bitmap & (1 << bit)) != 0;
    }

    function popCount(uint256 x) internal pure returns (uint256 count) {
        while (x != 0) {
            x &= x - 1;
            count++;
        }
    }

    function createBitMask(uint8 from, uint8 to) internal pure returns (uint256 mask) {
        require(from <= to, "BitMath: invalid range");
        require(to < 256, "BitMath: bit overflow");

        if (to == 255) {
            mask = type(uint256).max << from;
        } else {
            mask = ((1 << (to + 1)) - 1) & ~((1 << from) - 1);
        }
    }
}
