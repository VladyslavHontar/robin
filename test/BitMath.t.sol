pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BitMath} from "../src/trading/domain/services/BitMath.sol";

/// @notice Wrapper to expose internal BitMath functions as external calls
/// so vm.expectRevert works correctly (it needs an external call boundary).
contract BitMathWrapper {
    function mostSignificantBit(uint256 x) external pure returns (uint8) {
        return BitMath.mostSignificantBit(x);
    }

    function leastSignificantBit(uint256 x) external pure returns (uint8) {
        return BitMath.leastSignificantBit(x);
    }

    function createBitMask(uint8 from, uint8 to) external pure returns (uint256) {
        return BitMath.createBitMask(from, to);
    }
}

contract BitMathTest is Test {
    BitMathWrapper wrapper;

    function setUp() public {
        wrapper = new BitMathWrapper();
    }

    function testMostSignificantBit_PowerOfTwo() public pure {
        // Powers of 2 have exactly one bit set
        assertEq(BitMath.mostSignificantBit(1), 0, "MSB of 1 should be 0");
        assertEq(BitMath.mostSignificantBit(2), 1, "MSB of 2 should be 1");
        assertEq(BitMath.mostSignificantBit(4), 2, "MSB of 4 should be 2");
        assertEq(BitMath.mostSignificantBit(8), 3, "MSB of 8 should be 3");
        assertEq(BitMath.mostSignificantBit(256), 8, "MSB of 256 should be 8");
        assertEq(BitMath.mostSignificantBit(1 << 255), 255, "MSB of 2^255 should be 255");
    }

    function testMostSignificantBit_NonPowerOfTwo() public pure {
        assertEq(BitMath.mostSignificantBit(3), 1, "MSB of 3 (0b11) should be 1");
        assertEq(BitMath.mostSignificantBit(7), 2, "MSB of 7 (0b111) should be 2");
        assertEq(BitMath.mostSignificantBit(255), 7, "MSB of 255 should be 7");
        assertEq(BitMath.mostSignificantBit(1023), 9, "MSB of 1023 should be 9");
    }

    function testLeastSignificantBit_PowerOfTwo() public pure {
        assertEq(BitMath.leastSignificantBit(1), 0, "LSB of 1 should be 0");
        assertEq(BitMath.leastSignificantBit(2), 1, "LSB of 2 should be 1");
        assertEq(BitMath.leastSignificantBit(4), 2, "LSB of 4 should be 2");
        assertEq(BitMath.leastSignificantBit(8), 3, "LSB of 8 should be 3");
    }

    function testLeastSignificantBit_NonPowerOfTwo() public pure {
        assertEq(BitMath.leastSignificantBit(6), 1, "LSB of 6 (0b110) should be 1");
        assertEq(BitMath.leastSignificantBit(12), 2, "LSB of 12 (0b1100) should be 2");
        assertEq(BitMath.leastSignificantBit(24), 3, "LSB of 24 (0b11000) should be 3");
    }

    function testClosestBitLeft_Include() public pure {
        // Bitmap: 0b1010 (bits 3 and 1 are set)
        uint256 bitmap = 10; // 0b1010

        (uint8 bit, bool found) = BitMath.closestBitLeft(bitmap, 3, true);
        assertTrue(found, "Should find bit 3");
        assertEq(bit, 3, "Closest bit left including 3 should be 3");

        (bit, found) = BitMath.closestBitLeft(bitmap, 2, true);
        assertTrue(found, "Should find bit 1");
        assertEq(bit, 1, "Closest bit left from 2 should be 1");
    }

    function testClosestBitLeft_Exclude() public pure {
        // Bitmap: 0b1010 (bits 3 and 1 are set)
        uint256 bitmap = 10;

        (uint8 bit, bool found) = BitMath.closestBitLeft(bitmap, 3, false);
        assertTrue(found, "Should find bit 1");
        assertEq(bit, 1, "Closest bit left excluding 3 should be 1");

        (, found) = BitMath.closestBitLeft(bitmap, 0, false);
        assertFalse(found, "Should not find any bit left of 0");
    }

    function testClosestBitRight_Include() public pure {
        // Bitmap: 0b1010 (bits 3 and 1 are set)
        uint256 bitmap = 10;

        (uint8 bit, bool found) = BitMath.closestBitRight(bitmap, 0, true);
        assertTrue(found, "Should find bit 1");
        assertEq(bit, 1, "Closest bit right from 0 should be 1");

        (bit, found) = BitMath.closestBitRight(bitmap, 1, true);
        assertTrue(found, "Should find bit 1");
        assertEq(bit, 1, "Closest bit right including 1 should be 1");
    }

    function testClosestBitRight_Exclude() public pure {
        // Bitmap: 0b1010 (bits 3 and 1 are set)
        uint256 bitmap = 10;

        (uint8 bit, bool found) = BitMath.closestBitRight(bitmap, 1, false);
        assertTrue(found, "Should find bit 3");
        assertEq(bit, 3, "Closest bit right excluding 1 should be 3");

        (bit, found) = BitMath.closestBitRight(bitmap, 2, false);
        assertTrue(found, "Should find bit 3");
        assertEq(bit, 3, "Closest bit right from 2 should be 3");
    }

    function testSetBit() public pure {
        uint256 bitmap = 0;

        bitmap = BitMath.setBit(bitmap, 0);
        assertEq(bitmap, 1, "Setting bit 0 should give 1");

        bitmap = BitMath.setBit(bitmap, 2);
        assertEq(bitmap, 5, "Setting bit 2 should give 5 (0b101)");

        bitmap = BitMath.setBit(bitmap, 5);
        assertEq(bitmap, 37, "Setting bit 5 should give 37 (0b100101)");
    }

    function testClearBit() public pure {
        uint256 bitmap = 37; // 0b100101 (bits 0, 2, 5 set)

        bitmap = BitMath.clearBit(bitmap, 0);
        assertEq(bitmap, 36, "Clearing bit 0 should give 36");

        bitmap = BitMath.clearBit(bitmap, 2);
        assertEq(bitmap, 32, "Clearing bit 2 should give 32");

        bitmap = BitMath.clearBit(bitmap, 5);
        assertEq(bitmap, 0, "Clearing bit 5 should give 0");
    }

    function testIsBitSet() public pure {
        uint256 bitmap = 10; // 0b1010

        assertTrue(BitMath.isBitSet(bitmap, 1), "Bit 1 should be set");
        assertTrue(BitMath.isBitSet(bitmap, 3), "Bit 3 should be set");
        assertFalse(BitMath.isBitSet(bitmap, 0), "Bit 0 should not be set");
        assertFalse(BitMath.isBitSet(bitmap, 2), "Bit 2 should not be set");
    }

    function testPopCount() public pure {
        assertEq(BitMath.popCount(0), 0, "0 should have 0 bits set");
        assertEq(BitMath.popCount(1), 1, "1 should have 1 bit set");
        assertEq(BitMath.popCount(3), 2, "3 (0b11) should have 2 bits set");
        assertEq(BitMath.popCount(7), 3, "7 (0b111) should have 3 bits set");
        assertEq(BitMath.popCount(15), 4, "15 (0b1111) should have 4 bits set");
        assertEq(BitMath.popCount(255), 8, "255 should have 8 bits set");
    }

    function testCreateBitMask() public pure {
        uint256 mask = BitMath.createBitMask(0, 0);
        assertEq(mask, 1, "Mask from 0 to 0 should be 1");

        mask = BitMath.createBitMask(0, 2);
        assertEq(mask, 7, "Mask from 0 to 2 should be 7 (0b111)");

        mask = BitMath.createBitMask(2, 4);
        assertEq(mask, 28, "Mask from 2 to 4 should be 28 (0b11100)");

        mask = BitMath.createBitMask(1, 3);
        assertEq(mask, 14, "Mask from 1 to 3 should be 14 (0b1110)");
    }

    function testBitOperations_Integration() public pure {
        // Start with empty bitmap
        uint256 bitmap = 0;

        // Set bins 10, 50, 100
        bitmap = BitMath.setBit(bitmap, 10);
        bitmap = BitMath.setBit(bitmap, 50);
        bitmap = BitMath.setBit(bitmap, 100);

        assertEq(BitMath.popCount(bitmap), 3, "Should have 3 bits set");

        // Find closest bit from 30 (should find 10)
        (uint8 bit, bool found) = BitMath.closestBitLeft(bitmap, 30, true);
        assertTrue(found);
        assertEq(bit, 10, "Closest left from 30 should be 10");

        // Find closest bit from 30 going right (should find 50)
        (bit, found) = BitMath.closestBitRight(bitmap, 30, true);
        assertTrue(found);
        assertEq(bit, 50, "Closest right from 30 should be 50");

        // Clear bit 50
        bitmap = BitMath.clearBit(bitmap, 50);
        assertFalse(BitMath.isBitSet(bitmap, 50), "Bit 50 should be cleared");

        // Now closest right from 30 should be 100
        (bit, found) = BitMath.closestBitRight(bitmap, 30, true);
        assertTrue(found);
        assertEq(bit, 100, "After clearing 50, closest right should be 100");
    }

    // ===========================
    //       FUZZ TESTS
    // ===========================

    function testFuzz_MostSignificantBit(uint256 x) public pure {
        vm.assume(x > 0);

        uint8 msb = BitMath.mostSignificantBit(x);

        // MSB should be less than 256
        assertTrue(msb < 256, "MSB should be valid");

        // 2^msb should be <= x
        assertTrue(1 << msb <= x, "2^msb should be <= x");

        // 2^(msb+1) should be > x (if msb < 255)
        if (msb < 255) {
            assertTrue(1 << (msb + 1) > x, "2^(msb+1) should be > x");
        }
    }

    function testFuzz_LeastSignificantBit(uint256 x) public pure {
        vm.assume(x > 0);

        uint8 lsb = BitMath.leastSignificantBit(x);

        // LSB should be less than 256
        assertTrue(lsb < 256, "LSB should be valid");

        // Bit at LSB position should be set
        assertTrue(BitMath.isBitSet(x, lsb), "Bit at LSB should be set");

        // All bits below LSB should be clear
        if (lsb > 0) {
            for (uint8 i = 0; i < lsb; i++) {
                assertFalse(BitMath.isBitSet(x, i), "Bits below LSB should be clear");
            }
        }
    }

    function testFuzz_SetClearBit(uint256 bitmap, uint8 bit) public pure {
        // Invariant: clearBit(setBit(x, b), b) always results in bit b being clear.
        // This equals clearBit(x, b) — the bit is always cleared regardless of original state.
        uint256 withBitSet = BitMath.setBit(bitmap, bit);
        uint256 result = BitMath.clearBit(withBitSet, bit);

        uint256 expected = bitmap & ~(uint256(1) << bit);
        assertEq(result, expected, "Set then clear should equal clearing original");
        assertFalse(BitMath.isBitSet(result, bit), "Bit should be clear after set+clear");
    }

    // ===========================
    //       REVERT TESTS
    // ===========================
    // Use wrapper contract for external call boundary so vm.expectRevert works.

    function testRevert_MostSignificantBit_Zero() public {
        vm.expectRevert("BitMath: zero has no msb");
        wrapper.mostSignificantBit(0);
    }

    function testRevert_LeastSignificantBit_Zero() public {
        vm.expectRevert("BitMath: zero has no lsb");
        wrapper.leastSignificantBit(0);
    }

    function testRevert_CreateBitMask_InvalidRange() public {
        vm.expectRevert("BitMath: invalid range");
        wrapper.createBitMask(5, 3); // from > to
    }
}
