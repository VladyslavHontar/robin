// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/trading/infrastructure/LBFactory.sol";
import "../src/trading/domain/LBPair.sol";
import "../src/trading/domain/services/BinMath.sol";
import "../src/trading/domain/kernel/ILBPairTypes.sol";
import "../src/shared/mocks/MockERC20.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Regression test for the "swap ignores bin price" critical bug.
contract SwapPriceTest is Test {
    LBFactory public factory;
    LBPair public pair;
    MockERC20 public tokenX;
    MockERC20 public tokenY;

    address public lp = address(0xA11CE);
    address public trader = address(0xB0B);

    uint24 constant INITIAL_BIN_ID = 8_388_608;
    uint16 constant BIN_STEP = 50; // 0.5%
    // ~139 bins above center @ 0.5% step ~= price 2x.
    uint24 constant ACTIVE_ID = INITIAL_BIN_ID + 139;

    function setUp() public {
        LBPair impl = new LBPair();
        LBFactory factoryImpl = new LBFactory();
        factory = LBFactory(address(new TransparentUpgradeableProxy(
            address(factoryImpl), address(this),
            abi.encodeCall(LBFactory.initialize, (address(this), address(this), address(impl)))
        )));

        tokenX = new MockERC20("Token X", "X", 18);
        tokenY = new MockERC20("Token Y", "Y", 18);

        pair = LBPair(factory.createPair(address(tokenX), address(tokenY), BIN_STEP, ACTIVE_ID));

        tokenX.mint(lp, 1_000 ether);
        tokenY.mint(lp, 1_000 ether);
        tokenX.mint(trader, 1_000 ether);
        tokenY.mint(trader, 1_000 ether);

        // Market hours (15:00 UTC) so FeeHelper fee == baseFee (30 bps), no off-hours multiplier.
        vm.warp(15 * 3600);

        // LP seeds the single active bin with both tokens.
        vm.startPrank(lp);
        tokenX.approve(address(pair), type(uint256).max);
        tokenY.approve(address(pair), type(uint256).max);

        uint24[] memory binIds = new uint24[](1);
        binIds[0] = ACTIVE_ID;
        uint64[] memory dist = new uint64[](1);
        dist[0] = 1e18;

        pair.mint(ILBPairTypes.LiquidityParameters({
            binIds: binIds,
            distributionX: dist,
            distributionY: dist,
            amountX: 100 ether,
            amountY: 100 ether,
            activeIdDesired: ACTIVE_ID,
            idSlippage: 0,
            deadline: block.timestamp,
            to: lp
        }));
        vm.stopPrank();
    }

    function test_swapAppliesBinPrice_notOneToOne() public {
        uint256 price = BinMath.getPriceFromId(ACTIVE_ID, BIN_STEP); // Y per X, scaled by SCALE
        assertGt(price, BinMath.SCALE, "active bin price should be > 1");

        bool swapForY = address(tokenX) == pair.tokenX(); // input X -> output Y
        address tokenIn = swapForY ? pair.tokenX() : pair.tokenY();
        address tokenOut = swapForY ? pair.tokenY() : pair.tokenX();

        uint256 amountIn = 1 ether;
        uint256 feeBps = 30; // baseFee at market hours, same bin (no volatility), no oracle
        uint256 effectiveInput = amountIn - (amountIn * feeBps) / 10_000;

        uint256 expectedOut = swapForY
            ? (effectiveInput * price) / BinMath.SCALE
            : (effectiveInput * BinMath.SCALE) / price;

        uint256 outBefore = MockERC20(tokenOut).balanceOf(trader);

        vm.startPrank(trader);
        MockERC20(tokenIn).approve(address(pair), type(uint256).max);
        ILBPairTypes.SwapResult memory r = pair.swap(ILBPairTypes.SwapParameters({
            swapForY: swapForY,
            amountIn: amountIn,
            minAmountOut: 0,
            deadline: block.timestamp,
            to: trader
        }));
        vm.stopPrank();

        uint256 received = MockERC20(tokenOut).balanceOf(trader) - outBefore;

        // Output must follow the bin price, NOT 1:1.
        assertEq(r.amountOut, expectedOut, "amountOut must equal price-weighted output");
        assertEq(received, expectedOut, "transferred output must match");
        assertApproxEqRel(received, 2 ether, 0.02e18, "~2x output expected at this bin");
        assertGt(received, (effectiveInput * 15) / 10, "output clearly above 1:1");
    }
}
