// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/LBFactory.sol";
import "../src/LBPair.sol";
import "../src/LBRouter.sol";
import "../src/mocks/MockERC20.sol";
import "../src/interfaces/ILBPairTypes.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract FeeAccumulationTest is Test {
    LBFactory public factory;
    LBRouter public router;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    LBPair public pair;

    // After factory sorts, these point to the pair's actual tokenX/tokenY
    address public pairTokenX;
    address public pairTokenY;

    address public alice = address(0x1);
    address public bob = address(0x2);

    uint24 constant INITIAL_BIN_ID = 8_388_608;
    uint16 constant BIN_STEP = 50; // 0.5%

    function setUp() public {
        LBPair implementation = new LBPair();
        LBFactory factoryImpl = new LBFactory();
        LBRouter routerImpl = new LBRouter();

        factory = LBFactory(address(new TransparentUpgradeableProxy(
            address(factoryImpl), address(this),
            abi.encodeCall(LBFactory.initialize, (address(this), address(this), address(implementation)))
        )));
        router = LBRouter(address(new TransparentUpgradeableProxy(
            address(routerImpl), address(this),
            abi.encodeCall(LBRouter.initialize, (address(factory)))
        )));

        tokenA = new MockERC20("Token A", "A", 18);
        tokenB = new MockERC20("Token B", "B", 18);

        address pairAddr = factory.createPair(
            address(tokenA), address(tokenB), BIN_STEP, INITIAL_BIN_ID
        );
        pair = LBPair(pairAddr);

        // Factory sorts tokens — get the actual order
        pairTokenX = pair.tokenX();
        pairTokenY = pair.tokenY();

        // Mint tokens
        tokenA.mint(alice, 1000 ether);
        tokenB.mint(alice, 1000 ether);
        tokenA.mint(bob, 1000 ether);
        tokenB.mint(bob, 1000 ether);

        vm.label(address(pair), "Pair");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
    }

    // =========================================================================
    //                              HELPERS
    // =========================================================================

    function _addLiquidity(address user, uint256 amountX, uint256 amountY) internal returns (uint256[] memory) {
        vm.startPrank(user);
        MockERC20(pairTokenX).approve(address(pair), amountX);
        MockERC20(pairTokenY).approve(address(pair), amountY);

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

        uint256[] memory shares = pair.mint(params);
        vm.stopPrank();
        return shares;
    }

    function _addLiquidityMultiBin(
        address user,
        uint24[] memory binIds,
        uint256 amountX,
        uint256 amountY
    ) internal returns (uint256[] memory) {
        vm.startPrank(user);
        MockERC20(pairTokenX).approve(address(pair), amountX);
        MockERC20(pairTokenY).approve(address(pair), amountY);

        uint64[] memory distX = new uint64[](binIds.length);
        uint64[] memory distY = new uint64[](binIds.length);
        for (uint256 i = 0; i < binIds.length; i++) {
            distX[i] = uint64(1e18 / binIds.length);
            distY[i] = uint64(1e18 / binIds.length);
        }

        ILBPairTypes.LiquidityParameters memory params = ILBPairTypes.LiquidityParameters({
            binIds: binIds,
            distributionX: distX,
            distributionY: distY,
            amountX: amountX,
            amountY: amountY,
            activeIdDesired: INITIAL_BIN_ID,
            idSlippage: 5,
            deadline: block.timestamp + 1,
            to: user
        });

        uint256[] memory shares = pair.mint(params);
        vm.stopPrank();
        return shares;
    }

    function _doSwap(address user, bool swapForY, uint256 amountIn) internal {
        vm.startPrank(user);
        address tokenIn = swapForY ? pairTokenX : pairTokenY;
        MockERC20(tokenIn).approve(address(pair), amountIn);

        ILBPairTypes.SwapParameters memory swapParams = ILBPairTypes.SwapParameters({
            swapForY: swapForY,
            to: user,
            amountIn: amountIn,
            minAmountOut: 0,
            deadline: block.timestamp + 1
        });
        pair.swap(swapParams);
        vm.stopPrank();
    }

    // =========================================================================
    //                              TESTS
    // =========================================================================

    function testBasicFeeAccumulation() public {
        // Alice provides liquidity
        _addLiquidity(alice, 50 ether, 50 ether);

        // Check no unclaimed fees before any swap
        uint24[] memory binIds = new uint24[](1);
        binIds[0] = INITIAL_BIN_ID;
        (uint256 feesX, uint256 feesY) = pair.getUnclaimedFees(alice, binIds);
        assertEq(feesX, 0, "No fees before swap (X)");
        assertEq(feesY, 0, "No fees before swap (Y)");

        // Execute a swap (tokenX → tokenY)
        _doSwap(alice, true, 1 ether);

        // Check fees accumulated
        (feesX, feesY) = pair.getUnclaimedFees(alice, binIds);
        assertGt(feesX, 0, "Should have tokenX fees after swapForY");
        assertEq(feesY, 0, "No tokenY fees for swapForY");

        // Collect fees
        uint256 balBefore = MockERC20(pairTokenX).balanceOf(alice);
        vm.prank(alice);
        (uint256 collectedX, uint256 collectedY) = pair.collectFees(binIds, alice);
        uint256 balAfter = MockERC20(pairTokenX).balanceOf(alice);

        assertEq(collectedX, feesX, "Collected should match unclaimed");
        assertEq(collectedY, 0);
        assertEq(balAfter - balBefore, collectedX, "Balance should increase by collected amount");

        // Verify fees are zero after collection
        (feesX, feesY) = pair.getUnclaimedFees(alice, binIds);
        assertEq(feesX, 0, "Fees should be zero after collection");
        assertEq(feesY, 0);
    }

    function testTwoLPsProportionalFees() public {
        // Alice deposits 70 ether, Bob deposits 30 ether (70/30 split)
        _addLiquidity(alice, 70 ether, 70 ether);
        _addLiquidity(bob, 30 ether, 30 ether);

        // Execute swap
        _doSwap(alice, true, 10 ether);

        // Check fee split
        uint24[] memory binIds = new uint24[](1);
        binIds[0] = INITIAL_BIN_ID;

        (uint256 aliceFeesX,) = pair.getUnclaimedFees(alice, binIds);
        (uint256 bobFeesX,) = pair.getUnclaimedFees(bob, binIds);

        assertGt(aliceFeesX, 0, "Alice should have fees");
        assertGt(bobFeesX, 0, "Bob should have fees");

        // Alice should get ~70% and Bob ~30%
        uint256 totalFees = aliceFeesX + bobFeesX;
        // Allow 1% tolerance for rounding
        assertApproxEqRel(aliceFeesX, (totalFees * 70) / 100, 0.01e18, "Alice should get ~70%");
        assertApproxEqRel(bobFeesX, (totalFees * 30) / 100, 0.01e18, "Bob should get ~30%");
    }

    function testTimeFairness() public {
        // Alice deposits first
        _addLiquidity(alice, 50 ether, 50 ether);

        // Swap 1: only Alice earns
        _doSwap(bob, true, 5 ether);

        // Bob deposits same amount
        _addLiquidity(bob, 50 ether, 50 ether);

        // Swap 2: both earn 50/50
        _doSwap(alice, true, 5 ether);

        uint24[] memory binIds = new uint24[](1);
        binIds[0] = INITIAL_BIN_ID;

        (uint256 aliceFeesX,) = pair.getUnclaimedFees(alice, binIds);
        (uint256 bobFeesX,) = pair.getUnclaimedFees(bob, binIds);

        // Alice earned from swap1 (100%) + swap2 (50%)
        // Bob earned from swap2 only (50%)
        assertGt(aliceFeesX, bobFeesX, "Alice should have earned more (was in pool longer)");
    }

    function testFeeCollectionOnReDeposit() public {
        _addLiquidity(alice, 50 ether, 50 ether);

        // Swap generates fees
        _doSwap(bob, true, 5 ether);

        uint24[] memory binIds = new uint24[](1);
        binIds[0] = INITIAL_BIN_ID;
        (uint256 pendingBefore,) = pair.getUnclaimedFees(alice, binIds);
        assertGt(pendingBefore, 0, "Should have pending fees");

        // Alice re-deposits — should auto-collect pending fees
        uint256 balBefore = MockERC20(pairTokenX).balanceOf(alice);
        _addLiquidity(alice, 10 ether, 10 ether);
        uint256 balAfter = MockERC20(pairTokenX).balanceOf(alice);

        // Balance change = pending fees collected - new deposit amount
        // She deposited 10 ether of tokenX but received pendingBefore fees
        // Net: balAfter = balBefore - 10 ether + pendingBefore
        uint256 expectedBal = balBefore - 10 ether + pendingBefore;
        assertEq(balAfter, expectedBal, "Should have auto-collected fees on re-deposit");

        // Pending should be reset to zero
        (uint256 pendingAfter,) = pair.getUnclaimedFees(alice, binIds);
        assertEq(pendingAfter, 0, "Pending fees should be zero after re-deposit");
    }

    function testFeeCollectionOnBurn() public {
        _addLiquidity(alice, 50 ether, 50 ether);

        // Swap generates fees
        _doSwap(bob, true, 5 ether);

        uint24[] memory binIds = new uint24[](1);
        binIds[0] = INITIAL_BIN_ID;
        (uint256 pendingFeesX,) = pair.getUnclaimedFees(alice, binIds);
        assertGt(pendingFeesX, 0, "Should have pending fees");

        // Get Alice's shares
        uint256 aliceShares = pair.balanceOf(alice, INITIAL_BIN_ID);

        // Burn all shares — should auto-collect fees
        uint256 balXBefore = MockERC20(pairTokenX).balanceOf(alice);
        uint256 balYBefore = MockERC20(pairTokenY).balanceOf(alice);

        vm.startPrank(alice);
        uint256[] memory sharesToBurn = new uint256[](1);
        sharesToBurn[0] = aliceShares;
        pair.burn(
            ILBPairTypes.RemoveLiquidityParameters({
                binIds: binIds,
                shares: sharesToBurn,
                minAmountX: 0,
                minAmountY: 0,
                deadline: block.timestamp + 1,
                to: alice
            })
        );
        vm.stopPrank();

        uint256 balXAfter = MockERC20(pairTokenX).balanceOf(alice);
        uint256 balYAfter = MockERC20(pairTokenY).balanceOf(alice);

        // Alice should have received principal + fees
        uint256 receivedX = balXAfter - balXBefore;
        uint256 receivedY = balYAfter - balYBefore;

        // receivedX includes principal share + pending fees
        assertGt(receivedX, 0, "Should receive tokenX (principal + fees)");
        assertGt(receivedY, 0, "Should receive tokenY (principal)");

        // Verify fees are now zero
        (uint256 postFeesX,) = pair.getUnclaimedFees(alice, binIds);
        assertEq(postFeesX, 0, "Fees should be zero after full burn");
    }

    function testPartialBurn() public {
        _addLiquidity(alice, 50 ether, 50 ether);

        _doSwap(bob, true, 5 ether);

        uint24[] memory binIds = new uint24[](1);
        binIds[0] = INITIAL_BIN_ID;
        (uint256 pendingFeesX,) = pair.getUnclaimedFees(alice, binIds);
        assertGt(pendingFeesX, 0, "Should have pending fees");

        uint256 aliceShares = pair.balanceOf(alice, INITIAL_BIN_ID);

        // Burn half shares — should collect ALL pending fees + half principal
        uint256 balXBefore = MockERC20(pairTokenX).balanceOf(alice);

        vm.startPrank(alice);
        uint256[] memory sharesToBurn = new uint256[](1);
        sharesToBurn[0] = aliceShares / 2;
        pair.burn(
            ILBPairTypes.RemoveLiquidityParameters({
                binIds: binIds,
                shares: sharesToBurn,
                minAmountX: 0,
                minAmountY: 0,
                deadline: block.timestamp + 1,
                to: alice
            })
        );
        vm.stopPrank();

        uint256 balXAfter = MockERC20(pairTokenX).balanceOf(alice);
        uint256 receivedX = balXAfter - balXBefore;

        // Should have received half principal + ALL pending fees
        assertGt(receivedX, 0, "Should receive tokens");

        // Pending fees should be zero (all collected during burn)
        (uint256 postFeesX,) = pair.getUnclaimedFees(alice, binIds);
        assertEq(postFeesX, 0, "Fees should be zero after partial burn");

        // Alice should still have shares
        uint256 remainingShares = pair.balanceOf(alice, INITIAL_BIN_ID);
        assertGt(remainingShares, 0, "Should still have shares");
    }

    function testNoFeesWithoutSwap() public {
        _addLiquidity(alice, 50 ether, 50 ether);

        uint24[] memory binIds = new uint24[](1);
        binIds[0] = INITIAL_BIN_ID;
        (uint256 feesX, uint256 feesY) = pair.getUnclaimedFees(alice, binIds);
        assertEq(feesX, 0);
        assertEq(feesY, 0);
    }

    function testMultiBinFeeCollection() public {
        // Add liquidity across 3 bins
        uint24[] memory binIds = new uint24[](3);
        binIds[0] = INITIAL_BIN_ID - 1;
        binIds[1] = INITIAL_BIN_ID;
        binIds[2] = INITIAL_BIN_ID + 1;

        _addLiquidityMultiBin(alice, binIds, 30 ether, 30 ether);

        // Swap through multiple bins (large enough to cross bins)
        _doSwap(bob, true, 15 ether);

        // Check fees across all bins
        (uint256 totalFeesX,) = pair.getUnclaimedFees(alice, binIds);
        assertGt(totalFeesX, 0, "Should have fees across multiple bins");

        // Collect all at once
        vm.prank(alice);
        (uint256 collectedX,) = pair.collectFees(binIds, alice);
        assertEq(collectedX, totalFeesX, "Should collect all fees");

        // Verify zero after collection
        (uint256 postFeesX,) = pair.getUnclaimedFees(alice, binIds);
        assertEq(postFeesX, 0);
    }

    function testOnlySelfCanCollect() public {
        _addLiquidity(alice, 50 ether, 50 ether);
        _doSwap(bob, true, 5 ether);

        uint24[] memory binIds = new uint24[](1);
        binIds[0] = INITIAL_BIN_ID;

        // Bob tries to collect Alice's fees — should revert
        vm.prank(bob);
        vm.expectRevert();
        pair.collectFees(binIds, alice);
    }

    function testReservesExcludeFees() public {
        _addLiquidity(alice, 50 ether, 50 ether);

        // Get reserves before swap
        (uint128 resXBefore, uint128 resYBefore) = pair.getBinReserves(INITIAL_BIN_ID);

        // Swap tokenX → tokenY (swapForY)
        uint256 swapAmount = 1 ether;
        _doSwap(bob, true, swapAmount);

        // Get reserves after swap
        (uint128 resXAfter, uint128 resYAfter) = pair.getBinReserves(INITIAL_BIN_ID);

        // reserveX should increase by effectiveInput (NOT effectiveInput + lpFee)
        // Fee is ~0.45% (30bps base + variable), so effectiveInput ≈ swapAmount * 0.9955
        uint256 reserveXIncrease = resXAfter - resXBefore;

        // The LP fee should NOT be in reserves
        // Total fee = swapAmount * feeBps / 10000
        // LP fee = totalFee * (10000 - protocolShare) / 10000
        // If fee was in reserves, reserveXIncrease would be larger
        // reserveXIncrease should be approximately swapAmount - totalFee
        assertLt(reserveXIncrease, swapAmount, "Reserve increase should be less than swap amount (fees taken)");

        // Check that unclaimed fees exist separately
        uint24[] memory binIds = new uint24[](1);
        binIds[0] = INITIAL_BIN_ID;
        (uint256 feesX,) = pair.getUnclaimedFees(alice, binIds);
        assertGt(feesX, 0, "Fees should be tracked separately from reserves");

        // reserveXIncrease + feesX + protocolFees should ≈ swapAmount
        uint256 protocolFeesX = pair.protocolFeesX();
        uint256 total = reserveXIncrease + feesX + protocolFeesX;
        // Allow small rounding tolerance
        assertApproxEqAbs(total, swapAmount, 10, "reserve + lpFees + protocolFees should equal swapAmount");
    }

    function testProtocolFeesStillWork() public {
        _addLiquidity(alice, 50 ether, 50 ether);

        // Swap
        _doSwap(bob, true, 10 ether);

        // Protocol fees should still accumulate
        uint256 protocolFeesX = pair.protocolFeesX();
        assertGt(protocolFeesX, 0, "Protocol fees should accumulate");

        // Collect protocol fees via factory
        uint256 balBefore = MockERC20(pairTokenX).balanceOf(address(this));
        factory.collectProtocolFees(address(pair));
        uint256 balAfter = MockERC20(pairTokenX).balanceOf(address(this));

        assertEq(balAfter - balBefore, protocolFeesX, "Should receive protocol fees");
        assertEq(pair.protocolFeesX(), 0, "Protocol fees should be zero after collection");
    }

    function testZeroSharesNoFees() public {
        uint24[] memory binIds = new uint24[](1);
        binIds[0] = INITIAL_BIN_ID;

        // User with no shares
        (uint256 feesX, uint256 feesY) = pair.getUnclaimedFees(bob, binIds);
        assertEq(feesX, 0);
        assertEq(feesY, 0);

        // Collecting with no shares should succeed with zero amounts
        vm.prank(bob);
        (uint256 collectedX, uint256 collectedY) = pair.collectFees(binIds, bob);
        assertEq(collectedX, 0);
        assertEq(collectedY, 0);
    }

    function testFeeGrowthPersistsAcrossDeposits() public {
        // Alice deposits first
        _addLiquidity(alice, 50 ether, 50 ether);

        // Swap generates fees (only Alice earns)
        _doSwap(bob, true, 5 ether);

        // Alice collects her fees
        uint24[] memory binIds = new uint24[](1);
        binIds[0] = INITIAL_BIN_ID;
        vm.prank(alice);
        pair.collectFees(binIds, alice);

        // Bob deposits (feeGrowth is already > 0, but Bob's debt matches it)
        _addLiquidity(bob, 50 ether, 50 ether);

        // Bob should have zero unclaimed fees (just deposited)
        (uint256 bobFeesX,) = pair.getUnclaimedFees(bob, binIds);
        assertEq(bobFeesX, 0, "Bob should have zero fees right after deposit");

        // Another swap — both earn
        _doSwap(alice, true, 5 ether);

        (uint256 aliceFeesX2,) = pair.getUnclaimedFees(alice, binIds);
        (uint256 bobFeesX2,) = pair.getUnclaimedFees(bob, binIds);

        assertGt(aliceFeesX2, 0, "Alice should earn from second swap");
        assertGt(bobFeesX2, 0, "Bob should earn from second swap");
    }
}
