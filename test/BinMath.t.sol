// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/libraries/BinMath.sol";

contract BinMathTest is Test {
    using BinMath for *;

    uint24 constant INITIAL_BIN_ID = BinMath.INITIAL_BIN_ID;
    uint256 constant SCALE = BinMath.SCALE;

    function testGetPriceFromId_InitialBin() public pure {
        // At initial bin, price should be exactly SCALE (1.0)
        uint256 price = BinMath.getPriceFromId(INITIAL_BIN_ID, 100);
        assertEq(price, SCALE, "Initial bin should have price = 1.0");
    }

    function testGetPriceFromId_OneBinUp() public view {
        // One bin up with 100bp step should be 1.01x the base price
        uint256 price = BinMath.getPriceFromId(INITIAL_BIN_ID + 1, 100);
        uint256 expected = (SCALE * 10100) / 10000; // 1.01 * SCALE

        console.log("Price one bin up:", price);
        console.log("Expected:", expected);

        // Allow 0.1% tolerance for rounding
        uint256 tolerance = expected / 1000;
        assertApproxEqAbs(price, expected, tolerance, "One bin up should be ~1.01x");
    }

    function testGetPriceFromId_OneBinDown() public view {
        // One bin down with 100bp step should be ~0.99x the base price
        uint256 price = BinMath.getPriceFromId(INITIAL_BIN_ID - 1, 100);
        uint256 expected = (SCALE * 10000) / 10100; // 1/1.01 * SCALE

        console.log("Price one bin down:", price);
        console.log("Expected:", expected);

        uint256 tolerance = expected / 1000;
        assertApproxEqAbs(price, expected, tolerance, "One bin down should be ~0.99x");
    }

    function testGetPriceFromId_MultipleBins() public pure {
        // 10 bins up with 100bp (1%) step
        uint256 price = BinMath.getPriceFromId(INITIAL_BIN_ID + 10, 100);

        // Should be approximately 1.01^10 ≈ 1.1046
        uint256 expected = (SCALE * 11046) / 10000;

        // Allow 1% tolerance
        uint256 tolerance = expected / 100;
        assertApproxEqAbs(price, expected, tolerance, "10 bins up should be ~1.1046x");
    }

    function testGetPriceFromId_TightBinStep() public pure {
        // Test with 10bp (0.1%) bin step
        uint256 price1 = BinMath.getPriceFromId(INITIAL_BIN_ID + 1, 10);
        uint256 expected1 = (SCALE * 10010) / 10000; // 1.001x

        uint256 tolerance = expected1 / 1000;
        assertApproxEqAbs(price1, expected1, tolerance, "Tight bin step should work");
    }

    function testGetPriceFromId_WideBinStep() public pure {
        // Test with 1000bp (10%) bin step
        uint256 price1 = BinMath.getPriceFromId(INITIAL_BIN_ID + 1, 1000);
        uint256 expected1 = (SCALE * 11000) / 10000; // 1.10x

        uint256 tolerance = expected1 / 100;
        assertApproxEqAbs(price1, expected1, tolerance, "Wide bin step should work");
    }

    function testGetIdFromPrice_ExactMatch() public pure {
        // Get price for a specific bin, then get bin ID back
        uint24 originalBinId = INITIAL_BIN_ID + 5;
        uint256 price = BinMath.getPriceFromId(originalBinId, 100);
        uint24 retrievedBinId = BinMath.getIdFromPrice(price, 100);

        // Should get back the same or adjacent bin (due to rounding)
        assertApproxEqAbs(
            retrievedBinId,
            originalBinId,
            1,
            "Should retrieve same or adjacent bin ID"
        );
    }

    function testGetIdFromPrice_BelowInitialBin() public pure {
        // Test price below 1.0 (below initial bin)
        uint256 price = SCALE / 2; // 0.5x
        uint24 binId = BinMath.getIdFromPrice(price, 100);

        assertTrue(binId < INITIAL_BIN_ID, "Bin ID should be below initial for price < 1.0");
    }

    function testGetIdFromPrice_AboveInitialBin() public pure {
        // Test price above 1.0 (above initial bin)
        uint256 price = SCALE * 2; // 2.0x
        uint24 binId = BinMath.getIdFromPrice(price, 100);

        assertTrue(binId > INITIAL_BIN_ID, "Bin ID should be above initial for price > 1.0");
    }

    function testGetBasePriceOfBin() public pure {
        uint24 binId = INITIAL_BIN_ID + 10;
        uint256 basePrice = BinMath.getBasePriceOfBin(binId, 100);
        uint256 expected = BinMath.getPriceFromId(binId, 100);

        assertEq(basePrice, expected, "Base price should match getPriceFromId");
    }

    function testGetUpperPriceOfBin() public pure {
        uint24 binId = INITIAL_BIN_ID + 10;
        uint256 upperPrice = BinMath.getUpperPriceOfBin(binId, 100);
        uint256 expected = BinMath.getPriceFromId(binId + 1, 100);

        assertEq(upperPrice, expected, "Upper price should be next bin's base price");
    }

    function testIsPriceInBin() public pure {
        uint24 binId = INITIAL_BIN_ID + 5;
        uint256 basePrice = BinMath.getBasePriceOfBin(binId, 100);
        uint256 upperPrice = BinMath.getUpperPriceOfBin(binId, 100);

        // Price at base should be in bin
        assertTrue(BinMath.isPriceInBin(basePrice, binId, 100), "Base price should be in bin");

        // Price just below upper should be in bin
        uint256 midPrice = (basePrice + upperPrice) / 2;
        assertTrue(BinMath.isPriceInBin(midPrice, binId, 100), "Mid price should be in bin");

        // Price at upper bound should NOT be in bin (exclusive upper bound)
        assertFalse(
            BinMath.isPriceInBin(upperPrice, binId, 100),
            "Upper price should not be in bin"
        );
    }

    function testGetPriceRatio() public pure {
        uint24 binId1 = INITIAL_BIN_ID + 10;
        uint24 binId2 = INITIAL_BIN_ID + 5;

        uint256 ratio = BinMath.getPriceRatio(binId1, binId2, 100);

        // Ratio should be (1.01^10) / (1.01^5) = 1.01^5
        uint256 price1 = BinMath.getPriceFromId(binId1, 100);
        uint256 price2 = BinMath.getPriceFromId(binId2, 100);
        uint256 expectedRatio = (price1 * SCALE) / price2;

        assertEq(ratio, expectedRatio, "Price ratio should match manual calculation");
    }

    function testFromHumanPrice() public pure {
        // Convert $150 (with 6 decimals like USDC) to scaled price
        uint256 humanPrice = 150 * 1e6;  // $150 USDC
        uint256 scaledPrice = BinMath.fromHumanPrice(humanPrice, 6);

        // Should be 150 * SCALE
        uint256 expected = 150 * SCALE;
        assertEq(scaledPrice, expected, "Human price conversion should work");
    }

    function testToHumanPrice() public pure {
        // Convert scaled price back to human-readable
        uint256 scaledPrice = 150 * SCALE;
        uint256 humanPrice = BinMath.toHumanPrice(scaledPrice, 6);

        uint256 expected = 150 * 1e6;  // $150 with 6 decimals
        assertEq(humanPrice, expected, "Scaled to human conversion should work");
    }

    function testRoundTripConversion() public pure {
        // Human -> Scaled -> Human should preserve value
        uint256 original = 12345 * 1e18;  // Some ETH amount
        uint256 scaled = BinMath.fromHumanPrice(original, 18);
        uint256 recovered = BinMath.toHumanPrice(scaled, 18);

        assertEq(recovered, original, "Round-trip conversion should preserve value");
    }

    // Fuzz tests
    function testFuzz_GetPriceFromId(uint24 binId, uint16 binStep) public pure {
        // Constrain inputs to valid ranges
        binStep = uint16(bound(binStep, 1, BinMath.MAX_BIN_STEP));

        // Should not revert for any valid bin ID and bin step
        uint256 price = BinMath.getPriceFromId(binId, binStep);

        // Price should always be positive
        assertTrue(price > 0, "Price should be positive");
    }

    function testFuzz_GetIdFromPrice(uint256 price, uint16 binStep) public pure {
        // Constrain inputs
        price = bound(price, 1, type(uint128).max); // Reasonable price range
        binStep = uint16(bound(binStep, 1, BinMath.MAX_BIN_STEP));

        // Should not revert for valid inputs
        uint24 binId = BinMath.getIdFromPrice(price, binStep);

        // Bin ID should be valid
        assertTrue(binId < type(uint24).max, "Bin ID should be valid");
    }

    function testRevert_InvalidBinStep_Zero() public {
        vm.expectRevert("BinMath: invalid bin step");
        BinMath.getPriceFromId(INITIAL_BIN_ID, 0);
    }

    function testRevert_InvalidBinStep_TooHigh() public {
        vm.expectRevert("BinMath: invalid bin step");
        BinMath.getPriceFromId(INITIAL_BIN_ID, 10001);
    }

    function testRevert_InvalidPrice_Zero() public {
        vm.expectRevert("BinMath: price must be positive");
        BinMath.getIdFromPrice(0, 100);
    }
}
