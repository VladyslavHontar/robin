pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/trading/infrastructure/LBFactory.sol";
import "../src/trading/domain/LBPair.sol";
import "../src/trading/application/LBRouter.sol";
import "../src/trading/infrastructure/OracleModule.sol";
import "../src/shared/mocks/MockERC20.sol";
import "../src/shared/mocks/MockChainlinkAggregator.sol";
import "../src/trading/domain/kernel/ILBPairTypes.sol";
import "../src/trading/domain/ports/IOracleModule.sol";
import "../src/trading/domain/services/BinMath.sol";
import "../src/trading/domain/services/FeeHelper.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title Oracle Test
 * @notice Tests for OracleModule integration
 */
contract OracleTest is Test {
    LBFactory public factory;
    LBRouter public router;
    OracleModule public oracleModule;
    MockERC20 public tokenX;
    MockERC20 public tokenY;
    LBPair public pair;
    MockChainlinkAggregator public priceFeed;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public unauthorized = address(0x3);

    uint24 constant INITIAL_BIN_ID = 8_388_608;
    uint16 constant BIN_STEP = 50; // 0.5%
    uint256 constant MAX_STALENESS = 3600; // 1 hour

    function setUp() public {
        // Set reasonable timestamp (Foundry default is 1)
        vm.warp(1_700_000_000);

        // Deploy core contracts via proxies
        LBPair implementation = new LBPair();
        LBFactory factoryImpl = new LBFactory();
        LBRouter routerImpl = new LBRouter();
        OracleModule oracleImpl = new OracleModule();

        factory = LBFactory(address(new TransparentUpgradeableProxy(
            address(factoryImpl), owner,
            abi.encodeCall(LBFactory.initialize, (owner, owner, address(implementation)))
        )));
        router = LBRouter(address(new TransparentUpgradeableProxy(
            address(routerImpl), owner,
            abi.encodeCall(LBRouter.initialize, (address(factory)))
        )));
        oracleModule = OracleModule(address(new TransparentUpgradeableProxy(
            address(oracleImpl), owner,
            abi.encodeCall(OracleModule.initialize, (owner))
        )));

        // Set oracle on factory
        factory.setOracleModule(address(oracleModule));

        // Deploy tokens
        tokenX = new MockERC20("Token X", "X", 18);
        tokenY = new MockERC20("Token Y", "Y", 18);

        // Create pair (oracle auto-set by factory)
        address pairAddr = factory.createPair(
            address(tokenX),
            address(tokenY),
            BIN_STEP,
            INITIAL_BIN_ID
        );
        pair = LBPair(pairAddr);

        // Deploy mock Chainlink feed (8 decimals, $1.00 = price at SCALE)
        // Price = 1e8 means $1.00 with 8 decimals
        priceFeed = new MockChainlinkAggregator(8, 1e8);

        // Configure price feed for the pair
        oracleModule.setPriceFeed(address(pair), address(priceFeed), MAX_STALENESS);

        // Mint tokens
        tokenX.mint(alice, 1000 ether);
        tokenY.mint(alice, 1000 ether);
        tokenX.mint(bob, 1000 ether);
        tokenY.mint(bob, 1000 ether);

        // Labels
        vm.label(address(factory), "Factory");
        vm.label(address(router), "Router");
        vm.label(address(pair), "Pair");
        vm.label(address(oracleModule), "OracleModule");
        vm.label(address(priceFeed), "PriceFeed");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
    }

    // =============================================================
    //                   ORACLE MODULE BASICS
    // =============================================================

    function testOracleModuleDeployment() public view {
        assertEq(oracleModule.owner(), owner);
    }

    function testOracleSetOnPair() public view {
        assertEq(pair.oracle(), address(oracleModule));
    }

    function testFactoryAutoSetsOracle() public {
        // Create a new pair — should auto-get oracle
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        address newPair = factory.createPair(address(tokenA), address(tokenB), BIN_STEP, INITIAL_BIN_ID);
        assertEq(LBPair(newPair).oracle(), address(oracleModule));
    }

    function testSetPairOracleDirectly() public {
        // Deploy another oracle via proxy
        OracleModule oracle2Impl = new OracleModule();
        OracleModule oracle2 = OracleModule(address(new TransparentUpgradeableProxy(
            address(oracle2Impl), owner,
            abi.encodeCall(OracleModule.initialize, (owner))
        )));
        factory.setPairOracle(address(pair), address(oracle2));
        assertEq(pair.oracle(), address(oracle2));
    }

    function testDisableOracle() public {
        factory.setPairOracle(address(pair), address(0));
        assertEq(pair.oracle(), address(0));
    }

    // =============================================================
    //                     BIN ID CONVERSION
    // =============================================================

    function testOracleBinIdAtParity() public view {
        // Price = 1e8 ($1.00), 8 decimals → scaledPrice = 1e8 * 2^128 / 1e8 = SCALE
        // SCALE maps to INITIAL_BIN_ID
        (uint24 binId, bool isValid) = oracleModule.getOracleBinId(address(pair));
        assertTrue(isValid, "Should be valid");
        assertEq(binId, INITIAL_BIN_ID, "Should be at initial bin for $1.00");
    }

    function testOracleBinIdHigherPrice() public {
        // Set price slightly higher (avoid overflow in BinMath._pow for large exponents)
        priceFeed.setPrice(1.02e8); // $1.02
        (uint24 binId, bool isValid) = oracleModule.getOracleBinId(address(pair));
        assertTrue(isValid);
        assertTrue(binId > INITIAL_BIN_ID, "Higher price should give higher bin");
    }

    function testOracleBinIdLowerPrice() public {
        // Set price lower — bin should be below INITIAL_BIN_ID
        priceFeed.setPrice(0.5e8); // $0.50
        (uint24 binId, bool isValid) = oracleModule.getOracleBinId(address(pair));
        assertTrue(isValid);
        assertTrue(binId < INITIAL_BIN_ID, "Lower price should give lower bin");
    }

    // =============================================================
    //                     STALE PRICE HANDLING
    // =============================================================

    function testStaleReturnsInvalid() public {
        // Make price stale
        priceFeed.setStalePrice(1e8, MAX_STALENESS + 1);
        (uint24 binId, bool isValid) = oracleModule.getOracleBinId(address(pair));
        assertFalse(isValid, "Stale price should be invalid");
        assertEq(binId, 0, "Should return 0 for stale");
    }

    function testStaleReturnsZeroDeviationFee() public {
        priceFeed.setStalePrice(1e8, MAX_STALENESS + 1);
        uint256 fee = oracleModule.getDeviationFee(address(pair), INITIAL_BIN_ID);
        assertEq(fee, 0, "Stale price should give 0 deviation fee");
    }

    function testNegativePriceReturnsInvalid() public {
        priceFeed.setPrice(-1e8);
        (, bool isValid) = oracleModule.getOracleBinId(address(pair));
        assertFalse(isValid, "Negative price should be invalid");
    }

    function testZeroPriceReturnsInvalid() public {
        priceFeed.setPrice(0);
        (, bool isValid) = oracleModule.getOracleBinId(address(pair));
        assertFalse(isValid, "Zero price should be invalid");
    }

    function testNoFeedReturnsInvalid() public {
        // Query for a pair with no feed configured
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        address newPair = factory.createPair(address(tokenA), address(tokenB), 10, INITIAL_BIN_ID);

        (, bool isValid) = oracleModule.getOracleBinId(newPair);
        assertFalse(isValid, "No feed should return invalid");

        uint256 fee = oracleModule.getDeviationFee(newPair, INITIAL_BIN_ID);
        assertEq(fee, 0, "No feed should give 0 fee");
    }

    // =============================================================
    //                   DEVIATION FEE CALCULATION
    // =============================================================

    function testDeviationFeeInDeadzone() public view {
        // Oracle at INITIAL_BIN_ID, active at INITIAL_BIN_ID — no deviation
        uint256 fee = oracleModule.getDeviationFee(address(pair), INITIAL_BIN_ID);
        assertEq(fee, 0, "No deviation should give 0 fee");
    }

    function testDeviationFeeInDeadzoneEdge() public view {
        // Default 50bp params: deadzone = 1 bin
        // 1 bin deviation = still in deadzone
        uint256 fee = oracleModule.getDeviationFee(address(pair), INITIAL_BIN_ID + 1);
        assertEq(fee, 0, "1 bin deviation should be in deadzone for 50bp");
    }

    function testDeviationFeeTier1() public view {
        // 50bp defaults: deadzone=1, tier1Max=4, tier1Rate=10bp/bin
        // 3 bins deviation: (3 - 1) * 10 = 20bp
        uint256 fee = oracleModule.getDeviationFee(address(pair), INITIAL_BIN_ID + 3);
        assertEq(fee, 20, "3 bins should give 20bp deviation fee");
    }

    function testDeviationFeeTier2() public view {
        // 50bp defaults: tier1Max=4, tier2Max=8, tier2Rate=25bp/bin
        // 6 bins: tier1 = (4-1)*10 = 30bp, tier2 = (6-4)*25 = 50bp, total = 80bp
        uint256 fee = oracleModule.getDeviationFee(address(pair), INITIAL_BIN_ID + 6);
        assertEq(fee, 80, "6 bins should give 80bp deviation fee");
    }

    function testDeviationFeeCapped() public view {
        // 50bp defaults: maxDeviationFee = 130bp
        // 20 bins deviation should be capped at 130bp
        uint256 fee = oracleModule.getDeviationFee(address(pair), INITIAL_BIN_ID + 20);
        assertEq(fee, 130, "Large deviation should be capped at 130bp");
    }

    function testDeviationFeeSymmetric() public view {
        // Deviation in either direction should give same fee
        uint256 feeUp = oracleModule.getDeviationFee(address(pair), INITIAL_BIN_ID + 3);
        uint256 feeDown = oracleModule.getDeviationFee(address(pair), INITIAL_BIN_ID - 3);
        assertEq(feeUp, feeDown, "Fee should be symmetric");
    }

    // =============================================================
    //                  FeeHelper PURE FUNCTION TESTS
    // =============================================================

    function testGetOracleDeviationFeeDirectly() public pure {
        ILBPairTypes.OracleDeviationParams memory params = ILBPairTypes.OracleDeviationParams({
            deadzoneBins: 5,
            tier1MaxBins: 20,
            tier1RatePerBin: 2,
            tier2MaxBins: 40,
            tier2RatePerBin: 5,
            maxDeviationFee: 130
        });

        // In deadzone
        assertEq(FeeHelper.getOracleDeviationFee(INITIAL_BIN_ID, INITIAL_BIN_ID + 3, params), 0);

        // Tier 1: 10 bins deviation, (10-5)*2 = 10bp
        assertEq(FeeHelper.getOracleDeviationFee(INITIAL_BIN_ID, INITIAL_BIN_ID + 10, params), 10);

        // Tier 2: 30 bins, tier1=(20-5)*2=30bp, tier2=(30-20)*5=50bp, total=80bp
        assertEq(FeeHelper.getOracleDeviationFee(INITIAL_BIN_ID, INITIAL_BIN_ID + 30, params), 80);

        // Beyond tier 2: capped at 130bp
        assertEq(FeeHelper.getOracleDeviationFee(INITIAL_BIN_ID, INITIAL_BIN_ID + 50, params), 130);
    }

    // =============================================================
    //           SWAP INTEGRATION WITH ORACLE DEVIATION
    // =============================================================

    function testSwapWithOracleDeviationAddsFee() public {
        // Add liquidity
        _addLiquidity(alice, 50 ether, 50 ether);

        // Move oracle price so active bin deviates
        // Set oracle price higher so current bin (INITIAL) is "too low"
        // 50bp: 3 bins deviation → 20bp extra fee
        // We'll just verify fees are higher with oracle vs without

        // First, swap without deviation (oracle at parity)
        uint256 feesNoDeviation;
        {
            (, feesNoDeviation) = pair.getSwapOut(true, 5 ether);
        }

        // Now set oracle to a price that's 3 bins away
        // getPriceFromId(INITIAL_BIN_ID + 3, 50) gives the price 3 bins above
        // Price ~3 bins above: (1.005)^3 ≈ 1.015075 → 101507500
        priceFeed.setPrice(101507500);

        uint256 feesWithDeviation;
        {
            (, feesWithDeviation) = pair.getSwapOut(true, 5 ether);
        }

        assertTrue(feesWithDeviation > feesNoDeviation, "Fees should increase with oracle deviation");
    }

    function testSwapWithoutOracleUnchanged() public {
        // Disable oracle
        factory.setPairOracle(address(pair), address(0));

        // Add liquidity
        _addLiquidity(alice, 50 ether, 50 ether);

        // Swap should work normally
        vm.startPrank(bob);
        address pairTokenX = pair.tokenX();
        MockERC20(pairTokenX).approve(address(pair), 10 ether);

        ILBPairTypes.SwapParameters memory params = ILBPairTypes.SwapParameters({
            swapForY: true,
            amountIn: 5 ether,
            minAmountOut: 4 ether,
            deadline: block.timestamp + 1,
            to: bob
        });

        ILBPairTypes.SwapResult memory result = pair.swap(params);
        vm.stopPrank();

        assertTrue(result.amountOut > 0, "Swap should succeed without oracle");
    }

    // =============================================================
    //                  ROUTER ORACLE HELPERS
    // =============================================================

    function testRouterGetActiveBinFromOracle() public view {
        address pairTokenX = pair.tokenX();
        address pairTokenY = pair.tokenY();

        (uint24 oracleBinId, bool isValid) = router.getActiveBinFromOracle(
            pairTokenX, pairTokenY, BIN_STEP
        );
        assertTrue(isValid);
        assertEq(oracleBinId, INITIAL_BIN_ID);
    }

    function testRouterGetOracleDeviation() public view {
        address pairTokenX = pair.tokenX();
        address pairTokenY = pair.tokenY();

        (uint24 dexBinId, uint24 oracleBinId, uint24 deviationBins, uint256 extraFeeBps) =
            router.getOracleDeviation(pairTokenX, pairTokenY, BIN_STEP);

        assertEq(dexBinId, INITIAL_BIN_ID);
        assertEq(oracleBinId, INITIAL_BIN_ID);
        assertEq(deviationBins, 0);
        assertEq(extraFeeBps, 0);
    }

    function testRouterOracleNotSet() public {
        // Create pair without oracle
        factory.setOracleModule(address(0));
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        address newPair = factory.createPair(address(tokenA), address(tokenB), BIN_STEP, INITIAL_BIN_ID);

        address sortedX = LBPair(newPair).tokenX();
        address sortedY = LBPair(newPair).tokenY();

        vm.expectRevert(LBRouter.LBRouter__OracleNotSet.selector);
        router.getActiveBinFromOracle(sortedX, sortedY, BIN_STEP);
    }

    // =============================================================
    //                    ACCESS CONTROL
    // =============================================================

    function testOnlyOwnerCanSetPriceFeed() public {
        vm.prank(unauthorized);
        vm.expectRevert(IOracleModule.OracleModule__Unauthorized.selector);
        oracleModule.setPriceFeed(address(pair), address(priceFeed), 3600);
    }

    function testOnlyOwnerCanSetDeviationParams() public {
        ILBPairTypes.OracleDeviationParams memory params = ILBPairTypes.OracleDeviationParams({
            deadzoneBins: 2,
            tier1MaxBins: 10,
            tier1RatePerBin: 5,
            tier2MaxBins: 20,
            tier2RatePerBin: 10,
            maxDeviationFee: 200
        });

        vm.prank(unauthorized);
        vm.expectRevert(IOracleModule.OracleModule__Unauthorized.selector);
        oracleModule.setDeviationParams(address(pair), params);
    }

    function testTransferOwnership() public {
        oracleModule.transferOwnership(alice);
        // Two-step: owner unchanged until accepted
        assertEq(oracleModule.owner(), address(this));
        assertEq(oracleModule.pendingOwner(), alice);

        vm.prank(alice);
        oracleModule.acceptOwnership();
        assertEq(oracleModule.owner(), alice);
        assertEq(oracleModule.pendingOwner(), address(0));
    }

    function testAcceptOwnershipUnauthorized() public {
        oracleModule.transferOwnership(alice);
        vm.prank(unauthorized);
        vm.expectRevert(IOracleModule.OracleModule__Unauthorized.selector);
        oracleModule.acceptOwnership();
    }

    function testTransferOwnershipRejectsZero() public {
        vm.expectRevert(IOracleModule.OracleModule__ZeroAddress.selector);
        oracleModule.transferOwnership(address(0));
    }

    // =============================================================
    //                  CUSTOM DEVIATION PARAMS
    // =============================================================

    function testCustomDeviationParams() public {
        ILBPairTypes.OracleDeviationParams memory params = ILBPairTypes.OracleDeviationParams({
            deadzoneBins: 0,
            tier1MaxBins: 2,
            tier1RatePerBin: 50,
            tier2MaxBins: 5,
            tier2RatePerBin: 100,
            maxDeviationFee: 500
        });

        oracleModule.setDeviationParams(address(pair), params);

        // 1 bin deviation with custom params: (1-0)*50 = 50bp
        uint256 fee = oracleModule.getDeviationFee(address(pair), INITIAL_BIN_ID + 1);
        assertEq(fee, 50, "Custom params should apply");
    }

    function testDefaultDeviationParams() public view {
        // 10bp tier
        ILBPairTypes.OracleDeviationParams memory params10 = oracleModule.getDefaultDeviationParams(10);
        assertEq(params10.deadzoneBins, 5);
        assertEq(params10.tier1RatePerBin, 2);

        // 50bp tier
        ILBPairTypes.OracleDeviationParams memory params50 = oracleModule.getDefaultDeviationParams(50);
        assertEq(params50.deadzoneBins, 1);
        assertEq(params50.tier1RatePerBin, 10);

        // 100bp tier
        ILBPairTypes.OracleDeviationParams memory params100 = oracleModule.getDefaultDeviationParams(100);
        assertEq(params100.deadzoneBins, 1);
        assertEq(params100.tier1RatePerBin, 20);
    }

    function testGetOraclePrice() public view {
        (int256 price, uint8 decimals, uint256 updatedAt) = oracleModule.getOraclePrice(address(pair));
        assertEq(price, 1e8);
        assertEq(decimals, 8);
        assertTrue(updatedAt > 0);
    }

    // =============================================================
    //                    FUZZ TESTS
    // =============================================================

    function testFuzz_DeviationFeeMonotonicallyIncreases(uint24 deviation) public view {
        // Bound deviation to reasonable range
        deviation = uint24(bound(deviation, 0, 100));

        uint256 fee1 = oracleModule.getDeviationFee(address(pair), INITIAL_BIN_ID + deviation);

        if (deviation < 100) {
            uint256 fee2 = oracleModule.getDeviationFee(address(pair), INITIAL_BIN_ID + deviation + 1);
            assertTrue(fee2 >= fee1, "Fee should monotonically increase with deviation");
        }
    }

    function testFuzz_DeviationFeeAlwaysCapped(uint24 deviation) public view {
        deviation = uint24(bound(deviation, 0, 1000));

        uint256 fee = oracleModule.getDeviationFee(address(pair), INITIAL_BIN_ID + deviation);
        assertTrue(fee <= 130, "Fee should never exceed max deviation (130bp)");
    }

    // =============================================================
    //                     HELPERS
    // =============================================================

    function _addLiquidity(address user, uint256 amountX, uint256 amountY) internal {
        vm.startPrank(user);

        address pairTokenX = pair.tokenX();
        address pairTokenY = pair.tokenY();
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

        pair.mint(params);
        vm.stopPrank();
    }
}
