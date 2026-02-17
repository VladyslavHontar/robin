// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {LBFactory} from "../src/LBFactory.sol";
import {LBPair} from "../src/LBPair.sol";
import {LBRouter} from "../src/LBRouter.sol";
import {ILBPairTypes} from "../src/interfaces/ILBPairTypes.sol";
import {Identity} from "../src/compliance/Identity.sol";
import {ClaimIssuer} from "../src/compliance/ClaimIssuer.sol";
import {IdentityRegistry} from "../src/compliance/IdentityRegistry.sol";
import {ComplianceModule} from "../src/compliance/ComplianceModule.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract ComplianceTest is Test {
    // Contracts
    LBFactory factory;
    LBRouter router;
    LBPair pair;
    MockERC20 tokenA;
    MockERC20 tokenB;

    // Compliance stack
    IdentityRegistry identityRegistry;
    ComplianceModule complianceModule;
    ClaimIssuer claimIssuer;

    // Actors
    address owner = address(this);
    address kycProvider = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address charlie = address(0xC0C0); // unverified user

    // Identities
    Identity aliceIdentity;
    Identity bobIdentity;

    // Claim topics
    uint256 constant KYC_TOPIC = 1;
    uint256 constant AML_TOPIC = 2;

    // Country codes
    uint16 constant US = 840;
    uint16 constant UK = 826;

    uint16 binStep = 50;
    uint24 activeId = 8388608;

    function setUp() public {
        // Deploy tokens
        tokenA = new MockERC20("Stock AAPL", "AAPL", 18);
        tokenB = new MockERC20("USD Coin", "USDC", 18);

        // Deploy compliance stack
        identityRegistry = new IdentityRegistry(owner);
        complianceModule = new ComplianceModule(owner, address(identityRegistry));
        claimIssuer = new ClaimIssuer(kycProvider);

        // Register claim issuer as trusted for KYC topic
        uint256[] memory topics = new uint256[](1);
        topics[0] = KYC_TOPIC;
        identityRegistry.addTrustedIssuer(address(claimIssuer), topics);

        // Deploy DEX
        factory = new LBFactory(owner, owner);
        factory.setComplianceModule(address(complianceModule));

        router = new LBRouter(address(factory));

        // Create pair (compliance gets set automatically)
        address pairAddr = factory.createPair(
            address(tokenA),
            address(tokenB),
            binStep,
            activeId
        );
        pair = LBPair(pairAddr);

        // Whitelist the pair and router in compliance module
        complianceModule.setWhitelisted(pairAddr, true);
        complianceModule.setWhitelisted(address(router), true);

        // Setup Alice's identity & KYC
        _setupVerifiedUser(alice, US);

        // Setup Bob's identity & KYC
        _setupVerifiedUser(bob, UK);

        // Mint tokens
        tokenA.mint(alice, 1_000_000e18);
        tokenB.mint(alice, 1_000_000e18);
        tokenA.mint(bob, 1_000_000e18);
        tokenB.mint(bob, 1_000_000e18);
        tokenA.mint(charlie, 1_000_000e18);
        tokenB.mint(charlie, 1_000_000e18);
    }

    // =============================================================
    //                    IDENTITY TESTS
    // =============================================================

    function testIdentityCreation() public view {
        // Alice's identity should exist
        address aliceId = identityRegistry.identity(alice);
        assertEq(aliceId, address(aliceIdentity));

        // Bob's identity should exist
        address bobId = identityRegistry.identity(bob);
        assertEq(bobId, address(bobIdentity));

        // Charlie has no identity
        address charlieId = identityRegistry.identity(charlie);
        assertEq(charlieId, address(0));
    }

    function testCountryTracking() public view {
        assertEq(identityRegistry.investorCountry(alice), US);
        assertEq(identityRegistry.investorCountry(bob), UK);
    }

    function testClaimStorage() public view {
        // Alice's identity should have a KYC claim
        bytes32[] memory claimIds = aliceIdentity.getClaimIdsByTopic(KYC_TOPIC);
        assertEq(claimIds.length, 1);

        (uint256 topic,, address issuer,,,) = aliceIdentity.getClaim(claimIds[0]);
        assertEq(topic, KYC_TOPIC);
        assertEq(issuer, address(claimIssuer));
    }

    function testVerificationStatus() public view {
        assertTrue(identityRegistry.isVerified(alice));
        assertTrue(identityRegistry.isVerified(bob));
        assertFalse(identityRegistry.isVerified(charlie));
    }

    // =============================================================
    //                    COMPLIANCE GATE TESTS
    // =============================================================

    function testVerifiedUserCanSwap() public {
        // Alice adds liquidity first
        _addLiquidityAs(alice);

        // Bob can swap (he's verified)
        address pairTokenX = pair.tokenX();

        vm.startPrank(bob);
        MockERC20(pairTokenX).approve(address(pair), type(uint256).max);

        ILBPairTypes.SwapParameters memory swapParams = ILBPairTypes.SwapParameters({
            swapForY: true,
            amountIn: 100e18,
            minAmountOut: 0,
            deadline: block.timestamp + 1 hours,
            to: bob
        });

        ILBPairTypes.SwapResult memory result = pair.swap(swapParams);
        vm.stopPrank();

        assertGt(result.amountOut, 0, "Bob should receive output tokens");
    }

    function testUnverifiedUserCannotSwap() public {
        _addLiquidityAs(alice);

        address pairTokenX = pair.tokenX();

        vm.startPrank(charlie);
        MockERC20(pairTokenX).approve(address(pair), type(uint256).max);

        ILBPairTypes.SwapParameters memory swapParams = ILBPairTypes.SwapParameters({
            swapForY: true,
            amountIn: 100e18,
            minAmountOut: 0,
            deadline: block.timestamp + 1 hours,
            to: charlie
        });

        vm.expectRevert(
            abi.encodeWithSignature("LBPair__NotCompliant(address)", charlie)
        );
        pair.swap(swapParams);
        vm.stopPrank();
    }

    function testVerifiedUserCanAddLiquidity() public {
        // Alice (verified) can add liquidity
        _addLiquidityAs(alice);

        uint256 shares = pair.balanceOf(alice, activeId);
        assertGt(shares, 0, "Alice should have LP shares");
    }

    function testUnverifiedUserCannotAddLiquidity() public {
        address pairTokenX = pair.tokenX();
        address pairTokenY = pair.tokenY();

        vm.startPrank(charlie);
        MockERC20(pairTokenX).approve(address(pair), type(uint256).max);
        MockERC20(pairTokenY).approve(address(pair), type(uint256).max);

        uint24[] memory binIds = new uint24[](1);
        binIds[0] = activeId;
        uint64[] memory dist = new uint64[](1);
        dist[0] = 1e18;

        ILBPairTypes.LiquidityParameters memory params = ILBPairTypes.LiquidityParameters({
            binIds: binIds,
            distributionX: dist,
            distributionY: dist,
            amountX: 1000e18,
            amountY: 1000e18,
            activeIdDesired: activeId,
            idSlippage: 5,
            deadline: block.timestamp + 1 hours,
            to: charlie
        });

        vm.expectRevert(
            abi.encodeWithSignature("LBPair__NotCompliant(address)", charlie)
        );
        pair.mint(params);
        vm.stopPrank();
    }

    function testUnverifiedUserCannotRemoveLiquidity() public {
        // Alice adds liquidity
        _addLiquidityAs(alice);

        uint256 shares = pair.balanceOf(alice, activeId);

        // Alice tries to burn with `to` set to charlie (unverified)
        vm.startPrank(alice);

        uint24[] memory binIds = new uint24[](1);
        binIds[0] = activeId;
        uint256[] memory shareAmounts = new uint256[](1);
        shareAmounts[0] = shares;

        ILBPairTypes.RemoveLiquidityParameters memory params = ILBPairTypes.RemoveLiquidityParameters({
            binIds: binIds,
            shares: shareAmounts,
            minAmountX: 0,
            minAmountY: 0,
            deadline: block.timestamp + 1 hours,
            to: charlie  // unverified recipient
        });

        vm.expectRevert(
            abi.encodeWithSignature("LBPair__NotCompliant(address)", charlie)
        );
        pair.burn(params);
        vm.stopPrank();
    }

    // =============================================================
    //                  COUNTRY RESTRICTION TESTS
    // =============================================================

    function testCountryRestriction() public {
        address pairTokenX = pair.tokenX();

        // Enable country restrictions and only allow US
        complianceModule.setCountryRestrictionsEnabled(pairTokenX, true);
        complianceModule.setCountryAllowed(pairTokenX, US, true);
        // UK NOT allowed

        // canTransfer should pass for Alice (US) but fail for Bob (UK)
        assertTrue(
            complianceModule.canTransfer(pairTokenX, alice, alice, 100e18),
            "US user should pass"
        );
        assertFalse(
            complianceModule.canTransfer(pairTokenX, bob, bob, 100e18),
            "UK user should fail"
        );
    }

    function testBatchCountryAllowance() public {
        address pairTokenX = pair.tokenX();

        complianceModule.setCountryRestrictionsEnabled(pairTokenX, true);

        uint16[] memory countries = new uint16[](2);
        countries[0] = US;
        countries[1] = UK;
        bool[] memory allowed = new bool[](2);
        allowed[0] = true;
        allowed[1] = true;

        complianceModule.batchSetCountryAllowed(pairTokenX, countries, allowed);

        assertTrue(complianceModule.isCountryAllowed(pairTokenX, US));
        assertTrue(complianceModule.isCountryAllowed(pairTokenX, UK));
    }

    // =============================================================
    //                  TRANSFER LIMIT TESTS
    // =============================================================

    function testTransferLimits() public {
        address pairTokenX = pair.tokenX();

        // Set daily limit of 10,000 tokens
        complianceModule.setTransferLimits(pairTokenX, 10_000e18, 100_000e18);

        // Check limits
        (uint256 daily, uint256 monthly) = complianceModule.getTransferLimits(pairTokenX, alice);
        assertEq(daily, 10_000e18);
        assertEq(monthly, 100_000e18);

        // canTransfer should pass under limit
        assertTrue(
            complianceModule.canTransfer(pairTokenX, alice, bob, 5_000e18)
        );

        // canTransfer should fail over limit
        assertFalse(
            complianceModule.canTransfer(pairTokenX, alice, bob, 15_000e18)
        );
    }

    // =============================================================
    //                  CLAIM REVOCATION TESTS
    // =============================================================

    function testClaimRevocation() public {
        assertTrue(identityRegistry.isVerified(alice));

        // KYC provider revokes Alice's claim
        bytes32 claimId = keccak256(abi.encodePacked(address(claimIssuer), KYC_TOPIC));
        vm.prank(kycProvider);
        claimIssuer.revokeClaim(claimId);

        // Alice should no longer be verified
        assertFalse(identityRegistry.isVerified(alice));
    }

    function testClaimRevocationBlocksSwap() public {
        _addLiquidityAs(alice);

        // Revoke Bob's KYC
        bytes32 claimId = keccak256(abi.encodePacked(address(claimIssuer), KYC_TOPIC));
        vm.prank(kycProvider);
        claimIssuer.revokeClaim(claimId);

        // Bob can no longer swap
        address pairTokenX = pair.tokenX();

        vm.startPrank(bob);
        MockERC20(pairTokenX).approve(address(pair), type(uint256).max);

        ILBPairTypes.SwapParameters memory swapParams = ILBPairTypes.SwapParameters({
            swapForY: true,
            amountIn: 100e18,
            minAmountOut: 0,
            deadline: block.timestamp + 1 hours,
            to: bob
        });

        vm.expectRevert(
            abi.encodeWithSignature("LBPair__NotCompliant(address)", bob)
        );
        pair.swap(swapParams);
        vm.stopPrank();
    }

    // =============================================================
    //                  IDENTITY MANAGEMENT TESTS
    // =============================================================

    function testDeleteIdentity() public {
        assertTrue(identityRegistry.isVerified(alice));

        // Delete Alice's identity
        identityRegistry.deleteIdentity(alice);

        assertFalse(identityRegistry.isVerified(alice));
        assertEq(identityRegistry.identity(alice), address(0));
    }

    function testOnlyAgentCanRegister() public {
        vm.prank(charlie);
        vm.expectRevert(IdentityRegistry.IdentityRegistry__Unauthorized.selector);
        identityRegistry.registerIdentity(charlie, address(0x1), US);
    }

    function testAgentManagement() public {
        address newAgent = address(0xA6E0);

        identityRegistry.addAgent(newAgent);
        assertTrue(identityRegistry.isAgent(newAgent));

        identityRegistry.removeAgent(newAgent);
        assertFalse(identityRegistry.isAgent(newAgent));
    }

    // =============================================================
    //                  COMPLIANCE DISABLE TEST
    // =============================================================

    function testDisableCompliance() public {
        // Disable compliance on the pair
        factory.setPairCompliance(address(pair), address(0));

        // Now unverified charlie can swap
        _addLiquidityAs(alice);

        address pairTokenX = pair.tokenX();

        vm.startPrank(charlie);
        MockERC20(pairTokenX).approve(address(pair), type(uint256).max);

        ILBPairTypes.SwapParameters memory swapParams = ILBPairTypes.SwapParameters({
            swapForY: true,
            amountIn: 100e18,
            minAmountOut: 0,
            deadline: block.timestamp + 1 hours,
            to: charlie
        });

        // Should succeed without compliance
        ILBPairTypes.SwapResult memory result = pair.swap(swapParams);
        vm.stopPrank();

        assertGt(result.amountOut, 0);
    }

    // =============================================================
    //                  WHITELISTING TESTS
    // =============================================================

    function testWhitelistedAddressBypassesCompliance() public {
        // Whitelist charlie
        complianceModule.setWhitelisted(charlie, true);

        assertTrue(complianceModule.isVerified(charlie));
    }

    function testPairAndRouterAreWhitelisted() public view {
        assertTrue(complianceModule.whitelisted(address(pair)));
        assertTrue(complianceModule.whitelisted(address(router)));
    }

    // =============================================================
    //                    HELPERS
    // =============================================================

    function _setupVerifiedUser(address user, uint16 country) internal {
        // Create identity
        Identity id = new Identity(user);

        // Register in identity registry
        identityRegistry.registerIdentity(user, address(id), country);

        // Identity owner adds KYC claim from trusted issuer (scheme 0 = trust-based)
        vm.prank(user);
        id.addClaim(
            KYC_TOPIC,
            0,  // scheme 0 = trust-based
            address(claimIssuer),
            "",  // no signature for scheme 0
            abi.encode(user, block.timestamp), // claim data
            ""   // no URI
        );

        // Store reference
        if (user == alice) aliceIdentity = id;
        else if (user == bob) bobIdentity = id;
    }

    function _addLiquidityAs(address user) internal {
        address pairTokenX = pair.tokenX();
        address pairTokenY = pair.tokenY();

        vm.startPrank(user);
        MockERC20(pairTokenX).approve(address(pair), type(uint256).max);
        MockERC20(pairTokenY).approve(address(pair), type(uint256).max);

        uint24[] memory binIds = new uint24[](1);
        binIds[0] = activeId;
        uint64[] memory dist = new uint64[](1);
        dist[0] = 1e18;

        ILBPairTypes.LiquidityParameters memory params = ILBPairTypes.LiquidityParameters({
            binIds: binIds,
            distributionX: dist,
            distributionY: dist,
            amountX: 10_000e18,
            amountY: 10_000e18,
            activeIdDesired: activeId,
            idSlippage: 5,
            deadline: block.timestamp + 1 hours,
            to: user
        });

        pair.mint(params);
        vm.stopPrank();
    }
}
