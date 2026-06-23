// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/trading/infrastructure/LBFactory.sol";
import "../src/trading/infrastructure/OracleModule.sol";
import "../src/trading/domain/LBPair.sol";
import "../src/trading/domain/services/BinMath.sol";
import "../src/trading/domain/kernel/ILBPairTypes.sol";
import "../src/trading/domain/kernel/ILBPairErrors.sol";
import "../src/shared/mocks/MockERC20.sol";
import "../src/shared/mocks/MockChainlinkAggregator.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Regression tests for fixes #3 (price-move circuit breaker) and #4 (oracle hard-halt).
contract Fixes2Test is Test {
    LBFactory factory;
    address owner = address(this);
    address lp = address(0xA11CE);
    address trader = address(0xB0B);

    uint24 constant INITIAL_BIN_ID = 8_388_608;
    uint16 constant BIN_STEP = 50;

    function setUp() public {
        vm.warp(15 * 3600); // market hours → fee == baseFee, no off-hours multiplier
        LBPair impl = new LBPair();
        LBFactory fImpl = new LBFactory();
        factory = LBFactory(address(new TransparentUpgradeableProxy(
            address(fImpl), owner,
            abi.encodeCall(LBFactory.initialize, (owner, owner, address(impl)))
        )));
    }

    function _newTokens() internal returns (MockERC20 a, MockERC20 b) {
        a = new MockERC20("A", "A", 18);
        b = new MockERC20("B", "B", 18);
        a.mint(lp, 1_000_000 ether);
        b.mint(lp, 1_000_000 ether);
        a.mint(trader, 1_000_000 ether);
        b.mint(trader, 1_000_000 ether);
    }

    // Seed single-sided Y (the pair's tokenY) liquidity into `count` contiguous bins starting at `startBin`.
    function _mintYBins(LBPair pair, uint24 startBin, uint256 count, uint256 totalY) internal {
        uint24[] memory ids = new uint24[](count);
        uint64[] memory dX = new uint64[](count);
        uint64[] memory dY = new uint64[](count);
        for (uint256 i = 0; i < count; i++) {
            ids[i] = startBin + uint24(i);
            dY[i] = uint64(1e18 / count);
        }
        pair.mint(ILBPairTypes.LiquidityParameters({
            binIds: ids,
            distributionX: dX,
            distributionY: dY,
            amountX: 0,
            amountY: totalY,
            activeIdDesired: INITIAL_BIN_ID,
            idSlippage: 0,
            deadline: block.timestamp,
            to: lp
        }));
    }

    // ----------------------------------------------------------------
    // #3 — circuit breaker actually fires (was dead code at == loop cap)
    // ----------------------------------------------------------------
    function test_circuitBreaker_revertsWhenCrossingTooManyBins() public {
        (MockERC20 a, MockERC20 b) = _newTokens();
        LBPair pair = LBPair(factory.createPair(address(a), address(b), BIN_STEP, INITIAL_BIN_ID));
        MockERC20 pairY = MockERC20(pair.tokenY());

        // Seed 55 contiguous bins (> MAX_PRICE_MOVE_BINS = 50) just below the active bin.
        vm.startPrank(lp);
        pairY.approve(address(pair), type(uint256).max);
        _mintYBins(pair, INITIAL_BIN_ID - 50, 50, 50 ether); // bins [-50 .. -1]
        _mintYBins(pair, INITIAL_BIN_ID - 55, 5, 5 ether);   // bins [-55 .. -51]
        vm.stopPrank();

        // A large swapForY drains downward across all 55 bins → must trip the breaker.
        vm.startPrank(trader);
        MockERC20(pair.tokenX()).approve(address(pair), type(uint256).max);
        vm.expectPartialRevert(ILBPairErrors.LBPair__ExcessivePriceMove.selector);
        pair.swap(ILBPairTypes.SwapParameters({
            swapForY: true,
            amountIn: 1_000_000 ether,
            minAmountOut: 0,
            deadline: block.timestamp,
            to: trader
        }));
        vm.stopPrank();
    }

    // ----------------------------------------------------------------
    // #4 — oracle hard-halt blocks swaps when DEX price is far from oracle
    // ----------------------------------------------------------------
    function _setupOraclePair() internal returns (LBPair pair, MockChainlinkAggregator feed) {
        OracleModule oImpl = new OracleModule();
        OracleModule oracleModule = OracleModule(address(new TransparentUpgradeableProxy(
            address(oImpl), owner, abi.encodeCall(OracleModule.initialize, (owner))
        )));
        factory.setOracleModule(address(oracleModule));

        (MockERC20 a, MockERC20 b) = _newTokens();
        pair = LBPair(factory.createPair(address(a), address(b), BIN_STEP, INITIAL_BIN_ID));

        feed = new MockChainlinkAggregator(8, 1e8); // $1.00 → parity → oracle bin = INITIAL_BIN_ID
        oracleModule.setPriceFeed(address(pair), address(feed), 3600);

        // Seed the active bin with both tokens so a small swap stays inside it (0 bins crossed).
        uint24[] memory ids = new uint24[](1);
        ids[0] = INITIAL_BIN_ID;
        uint64[] memory d = new uint64[](1);
        d[0] = 1e18;
        vm.startPrank(lp);
        MockERC20(pair.tokenX()).approve(address(pair), type(uint256).max);
        MockERC20(pair.tokenY()).approve(address(pair), type(uint256).max);
        pair.mint(ILBPairTypes.LiquidityParameters({
            binIds: ids, distributionX: d, distributionY: d,
            amountX: 1000 ether, amountY: 1000 ether,
            activeIdDesired: INITIAL_BIN_ID, idSlippage: 0,
            deadline: block.timestamp, to: lp
        }));
        vm.stopPrank();
    }

    function _smallSwap(LBPair pair) internal {
        vm.startPrank(trader);
        MockERC20(pair.tokenX()).approve(address(pair), type(uint256).max);
        pair.swap(ILBPairTypes.SwapParameters({
            swapForY: true,
            amountIn: 1 ether,
            minAmountOut: 0,
            deadline: block.timestamp,
            to: trader
        }));
        vm.stopPrank();
    }

    function test_oracleHalt_blocksSwapWhenDeviationTooHigh() public {
        (LBPair pair, MockChainlinkAggregator feed) = _setupOraclePair();

        // Push oracle to $3 → oracle bin ~ +220 bins from the DEX active bin (>> 50).
        feed.setPrice(3e8);

        vm.startPrank(trader);
        MockERC20(pair.tokenX()).approve(address(pair), type(uint256).max);
        vm.expectPartialRevert(ILBPairErrors.LBPair__OracleDeviationTooHigh.selector);
        pair.swap(ILBPairTypes.SwapParameters({
            swapForY: true,
            amountIn: 1 ether,
            minAmountOut: 0,
            deadline: block.timestamp,
            to: trader
        }));
        vm.stopPrank();
    }

    function test_oracleHalt_canBeDisabledByFactory() public {
        (LBPair pair, MockChainlinkAggregator feed) = _setupOraclePair();
        feed.setPrice(3e8);

        // Disable the breaker → the same swap now succeeds.
        factory.setPairMaxOracleDeviationBins(address(pair), 0);
        _smallSwap(pair);
        assertEq(pair.maxOracleDeviationBins(), 0);
    }

    function test_oracleHalt_allowsSwapWithinThreshold() public {
        (LBPair pair, ) = _setupOraclePair();
        // Oracle stays at parity (bin == active); a small in-bin swap is well within 50 bins.
        _smallSwap(pair);
    }
}
