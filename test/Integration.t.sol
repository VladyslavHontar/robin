// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/LBFactory.sol";
import "../src/LBPair.sol";
import "../src/LBRouter.sol";
import "../src/mocks/MockERC20.sol";
import "../src/interfaces/ILBPairTypes.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title Integration Test
 * @notice End-to-end tests for the DLMM system
 */
contract IntegrationTest is Test {
    LBFactory public factory;
    LBRouter public router;
    MockERC20 public tokenX;
    MockERC20 public tokenY;
    LBPair public pair;

    address public alice = address(0x1);
    address public bob = address(0x2);

    uint24 constant INITIAL_BIN_ID = 8_388_608;
    uint16 constant BIN_STEP = 50; // 0.5%

    function setUp() public {
        // Deploy implementations
        LBPair implementation = new LBPair();
        LBFactory factoryImpl = new LBFactory();
        LBRouter routerImpl = new LBRouter();

        // Deploy proxies (matches production deployment)
        factory = LBFactory(address(new TransparentUpgradeableProxy(
            address(factoryImpl), address(this),
            abi.encodeCall(LBFactory.initialize, (address(this), address(this), address(implementation)))
        )));
        router = LBRouter(address(new TransparentUpgradeableProxy(
            address(routerImpl), address(this),
            abi.encodeCall(LBRouter.initialize, (address(factory)))
        )));

        // Deploy tokens
        tokenX = new MockERC20("Token X", "X", 18);
        tokenY = new MockERC20("Token Y", "Y", 18);

        // Create pair
        address pairAddr = factory.createPair(
            address(tokenX),
            address(tokenY),
            BIN_STEP,
            INITIAL_BIN_ID
        );
        pair = LBPair(pairAddr);

        // Mint tokens to test users
        tokenX.mint(alice, 1000 ether);
        tokenY.mint(alice, 1000 ether);
        tokenX.mint(bob, 1000 ether);
        tokenY.mint(bob, 1000 ether);

        // Setup labels for better trace output
        vm.label(address(factory), "Factory");
        vm.label(address(router), "Router");
        vm.label(address(pair), "Pair");
        vm.label(address(tokenX), "TokenX");
        vm.label(address(tokenY), "TokenY");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
    }

    function testDeployment() public view {
        // Note: Factory sorts tokens, so tokenX < tokenY in the pair
        // In this case, tokenY address < tokenX address, so they're swapped
        address pairTokenX = address(pair.tokenX());
        address pairTokenY = address(pair.tokenY());

        // Verify both tokens are present (order may be swapped)
        assertTrue(
            (pairTokenX == address(tokenX) && pairTokenY == address(tokenY)) ||
            (pairTokenX == address(tokenY) && pairTokenY == address(tokenX)),
            "Pair should contain both tokens"
        );

        assertEq(pair.binStep(), BIN_STEP);
        assertEq(pair.activeId(), INITIAL_BIN_ID);
    }

    function testAddLiquiditySingleBin() public {
        vm.startPrank(alice);

        // Approve tokens
        tokenX.approve(address(pair), 100 ether);
        tokenY.approve(address(pair), 100 ether);

        // Add liquidity to single bin (spot concentration)
        uint24[] memory binIds = new uint24[](1);
        binIds[0] = INITIAL_BIN_ID;

        uint64[] memory distX = new uint64[](1);
        distX[0] = 1e18; // 100%

        uint64[] memory distY = new uint64[](1);
        distY[0] = 1e18; // 100%

        ILBPairTypes.LiquidityParameters memory params = ILBPairTypes.LiquidityParameters({
            binIds: binIds,
            distributionX: distX,
            distributionY: distY,
            amountX: 50 ether,
            amountY: 50 ether,
            activeIdDesired: INITIAL_BIN_ID,
            idSlippage: 0,
            deadline: block.timestamp + 1,
            to: alice
        });

        uint256[] memory shares = pair.mint(params);

        vm.stopPrank();

        // Verify
        assertTrue(shares[0] > 0, "Should receive shares");
        assertEq(pair.balanceOf(alice, INITIAL_BIN_ID), shares[0]);

        (uint128 reserveX, uint128 reserveY) = pair.getBinReserves(INITIAL_BIN_ID);
        assertEq(reserveX, 50 ether);
        assertEq(reserveY, 50 ether);
    }

    function testSwapWithinSingleBin() public {
        // First add liquidity
        testAddLiquiditySingleBin();

        vm.startPrank(bob);

        // Get pair's sorted tokens
        address pairTokenX = address(pair.tokenX());
        address pairTokenY = address(pair.tokenY());

        // Approve the token we're selling (pair's tokenX if swapForY=true)
        MockERC20(pairTokenX).approve(address(pair), 10 ether);

        // Execute swap (swapping pair's tokenX for pair's tokenY)
        ILBPairTypes.SwapParameters memory params = ILBPairTypes.SwapParameters({
            swapForY: true, // Swapping pair's X for pair's Y
            amountIn: 5 ether,
            minAmountOut: 4 ether, // Allow some slippage/fees
            deadline: block.timestamp + 1,
            to: bob
        });

        uint256 balanceBeforeX = MockERC20(pairTokenX).balanceOf(bob);
        uint256 balanceBeforeY = MockERC20(pairTokenY).balanceOf(bob);

        ILBPairTypes.SwapResult memory result = pair.swap(params);

        vm.stopPrank();

        // Verify swap result
        assertTrue(result.amountOut > 0, "Should receive output tokens");
        assertTrue(result.amountOut >= 4 ether, "Should meet minimum output");
        assertEq(balanceBeforeX - MockERC20(pairTokenX).balanceOf(bob), 5 ether, "Should send 5 ether tokenX");
        assertEq(MockERC20(pairTokenY).balanceOf(bob) - balanceBeforeY, result.amountOut, "Should receive amountOut tokenY");
        assertEq(result.newActiveBinId, INITIAL_BIN_ID, "Should stay in same bin");
    }

    function testAddLiquidityMultipleBins() public {
        vm.startPrank(alice);

        tokenX.approve(address(pair), 300 ether);
        tokenY.approve(address(pair), 300 ether);

        // Add liquidity to 5 bins (2 below, active, 2 above)
        uint24[] memory binIds = new uint24[](5);
        binIds[0] = INITIAL_BIN_ID - 2;
        binIds[1] = INITIAL_BIN_ID - 1;
        binIds[2] = INITIAL_BIN_ID;
        binIds[3] = INITIAL_BIN_ID + 1;
        binIds[4] = INITIAL_BIN_ID + 2;

        // Distribution must sum to 1e18 (100%) for each token
        // Below active bins: only Y (60% total)
        // Active bin: both X and Y (20% each)
        // Above active bins: only X (60% total)
        uint64[] memory distX = new uint64[](5);
        uint64[] memory distY = new uint64[](5);

        for (uint256 i = 0; i < 5; i++) {
            if (binIds[i] < INITIAL_BIN_ID) {
                // Below active: only Y (30% each = 60% total)
                distX[i] = 0;
                distY[i] = 3e17; // 30%
            } else if (binIds[i] > INITIAL_BIN_ID) {
                // Above active: only X (30% each = 60% total)
                distX[i] = 3e17; // 30%
                distY[i] = 0;
            } else {
                // Active: both (20% each)
                distX[i] = 4e17; // 40% (remaining from 100% - 60%)
                distY[i] = 4e17; // 40% (remaining from 100% - 60%)
            }
        }

        ILBPairTypes.LiquidityParameters memory params = ILBPairTypes.LiquidityParameters({
            binIds: binIds,
            distributionX: distX,
            distributionY: distY,
            amountX: 100 ether,
            amountY: 100 ether,
            activeIdDesired: INITIAL_BIN_ID,
            idSlippage: 2,
            deadline: block.timestamp + 1,
            to: alice
        });

        uint256[] memory shares = pair.mint(params);

        vm.stopPrank();

        // Verify liquidity in multiple bins
        for (uint256 i = 0; i < 5; i++) {
            assertTrue(shares[i] > 0, "Should have shares in bin");
            (uint128 reserveX, uint128 reserveY) = pair.getBinReserves(binIds[i]);
            assertTrue(reserveX > 0 || reserveY > 0, "Should have reserves");
        }
    }

    function testSwapAcrossMultipleBins() public {
        // Add liquidity to multiple bins
        testAddLiquidityMultipleBins();

        vm.startPrank(bob);

        // Get pair's sorted tokens
        address pairTokenX = address(pair.tokenX());
        address pairTokenY = address(pair.tokenY());

        // Large swap that crosses bins
        MockERC20(pairTokenX).approve(address(pair), 50 ether);

        ILBPairTypes.SwapParameters memory params = ILBPairTypes.SwapParameters({
            swapForY: true, // Swapping pair's X for pair's Y
            amountIn: 30 ether,
            minAmountOut: 25 ether,
            deadline: block.timestamp + 1,
            to: bob
        });

        uint256 balanceBeforeX = MockERC20(pairTokenX).balanceOf(bob);
        uint256 balanceBeforeY = MockERC20(pairTokenY).balanceOf(bob);

        ILBPairTypes.SwapResult memory result = pair.swap(params);

        vm.stopPrank();

        // Verify
        assertTrue(result.amountOut >= 25 ether, "Should meet minimum");
        assertTrue(result.fees > 0, "Should collect fees");
        assertEq(balanceBeforeX - MockERC20(pairTokenX).balanceOf(bob), 30 ether, "Should send 30 ether tokenX");
        assertEq(MockERC20(pairTokenY).balanceOf(bob) - balanceBeforeY, result.amountOut, "Should receive amountOut tokenY");

        console.log("Swapped 30 ether X for", result.amountOut / 1e18, "ether Y");
        console.log("Fees collected:", result.fees / 1e18, "ether");
        console.log("Active bin moved from", INITIAL_BIN_ID, "to", result.newActiveBinId);
    }

    function testRemoveLiquidity() public {
        // Add liquidity first
        testAddLiquiditySingleBin();

        vm.startPrank(alice);

        // Get alice's shares
        uint256 shares = pair.balanceOf(alice, INITIAL_BIN_ID);
        assertTrue(shares > 0, "Alice should have shares");

        // Remove liquidity
        uint24[] memory binIds = new uint24[](1);
        binIds[0] = INITIAL_BIN_ID;

        uint256[] memory sharesToBurn = new uint256[](1);
        sharesToBurn[0] = shares;

        ILBPairTypes.RemoveLiquidityParameters memory params =
            ILBPairTypes.RemoveLiquidityParameters({
                binIds: binIds,
                shares: sharesToBurn,
                minAmountX: 0,
                minAmountY: 0,
                deadline: block.timestamp + 1,
                to: alice
            });

        uint256 xBefore = tokenX.balanceOf(alice);
        uint256 yBefore = tokenY.balanceOf(alice);

        (uint256 amountX, uint256 amountY) = pair.burn(params);

        vm.stopPrank();

        // Verify
        assertTrue(amountX > 0 || amountY > 0, "Should receive tokens back");
        assertEq(tokenX.balanceOf(alice) - xBefore, amountX);
        assertEq(tokenY.balanceOf(alice) - yBefore, amountY);
        assertEq(pair.balanceOf(alice, INITIAL_BIN_ID), 0, "Shares should be burned");
    }

    function testRouterSwap() public {
        // Add liquidity
        testAddLiquiditySingleBin();

        vm.startPrank(bob);

        // Get pair's sorted tokens
        address pairTokenX = address(pair.tokenX());
        address pairTokenY = address(pair.tokenY());

        // Approve router for the token we're selling (pair's tokenX)
        MockERC20(pairTokenX).approve(address(router), 10 ether);

        uint256 balanceBeforeX = MockERC20(pairTokenX).balanceOf(bob);
        uint256 balanceBeforeY = MockERC20(pairTokenY).balanceOf(bob);

        // Use router to swap (router handles sorting internally)
        uint256 amountOut = router.swapExactTokensForTokens(
            pairTokenX,
            pairTokenY,
            BIN_STEP,
            5 ether,
            4 ether,
            bob,
            block.timestamp + 1
        );

        vm.stopPrank();

        assertTrue(amountOut >= 4 ether, "Should meet minimum");
        assertEq(balanceBeforeX - MockERC20(pairTokenX).balanceOf(bob), 5 ether, "Should send 5 ether tokenX");
        assertEq(MockERC20(pairTokenY).balanceOf(bob) - balanceBeforeY, amountOut, "Should receive amountOut tokenY");
    }

    function testRouterQuote() public {
        // Add liquidity first
        testAddLiquiditySingleBin();

        // Get pair's sorted tokens
        address pairTokenX = address(pair.tokenX());
        address pairTokenY = address(pair.tokenY());

        // Get quote for swapping 10 ether X for Y
        (uint256 amountOut, uint256 fees) = router.getSwapQuote(
            pairTokenX,
            pairTokenY,
            BIN_STEP,
            10 ether
        );

        // Should return actual quote with liquidity
        assertTrue(amountOut > 0, "Should get quote output");
        console.log("Quote for 10 ether X:", amountOut / 1e18, "ether Y");
        console.log("Estimated fees:", fees / 1e18, "ether");
    }

    function testMultipleUsers() public {
        vm.startPrank(alice);
        tokenX.approve(address(pair), 100 ether);
        tokenY.approve(address(pair), 100 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        tokenX.approve(address(pair), 100 ether);
        tokenY.approve(address(pair), 100 ether);
        vm.stopPrank();

        // Alice adds liquidity
        vm.prank(alice);
        _addLiquidity(alice, 50 ether, 50 ether);

        // Bob adds liquidity to same bin
        vm.prank(bob);
        _addLiquidity(bob, 30 ether, 30 ether);

        // Verify both have shares
        assertTrue(pair.balanceOf(alice, INITIAL_BIN_ID) > 0);
        assertTrue(pair.balanceOf(bob, INITIAL_BIN_ID) > 0);
    }

    function _addLiquidity(address user, uint256 amountX, uint256 amountY) internal {
        uint24[] memory binIds = new uint24[](1);
        binIds[0] = INITIAL_BIN_ID;

        uint64[] memory distX = new uint64[](1);
        distX[0] = 1e18;

        uint64[] memory distY = new uint64[](1);
        distY[0] = 1e18;

        ILBPairTypes.LiquidityParameters memory params = ILBPairTypes.LiquidityParameters({
            binIds: binIds,
            distributionX: distX,
            distributionY: distY,
            amountX: amountX,
            amountY: amountY,
            activeIdDesired: INITIAL_BIN_ID,
            idSlippage: 0,
            deadline: block.timestamp + 1,
            to: user
        });

        pair.mint(params);
    }

    // =============================================================
    //              CREATE2 / PAIR ADDRESS DERIVATION
    // =============================================================

    /**
     * @notice computePairAddress must return the actual deployed pair address.
     * @dev This is the Solana PDA equivalent: derive any pair address offline
     *      using only (factory, tokenA, tokenB, binStep) — no chain query needed.
     */
    function testComputePairAddress_MatchesDeployed() public view {
        address computed = factory.computePairAddress(
            address(tokenX),
            address(tokenY),
            BIN_STEP
        );
        assertEq(computed, address(pair), "Derived address must match deployed pair");
    }

    /// @notice Order of tokens passed must not matter (factory sorts internally)
    function testComputePairAddress_TokenOrderInvariant() public view {
        address ab = factory.computePairAddress(address(tokenX), address(tokenY), BIN_STEP);
        address ba = factory.computePairAddress(address(tokenY), address(tokenX), BIN_STEP);
        assertEq(ab, ba, "Address must be the same regardless of token order");
    }

    /// @notice Address for a non-existent pair must differ from the deployed pair
    function testComputePairAddress_BeforeDeployment() public {
        // Deploy a fresh token not yet in a pair
        MockERC20 tokenZ = new MockERC20("Token Z", "Z", 18);

        // Compute address before pair is created
        address predicted = factory.computePairAddress(address(tokenX), address(tokenZ), BIN_STEP);

        // Verify pair doesn't exist yet
        assertEq(factory.getPair(address(tokenX), address(tokenZ), BIN_STEP), address(0));

        // Deploy the pair
        address created = factory.createPair(address(tokenX), address(tokenZ), BIN_STEP, INITIAL_BIN_ID);

        // Prediction must match actual address
        assertEq(predicted, created, "Pre-deployment prediction must match created address");
    }
}
