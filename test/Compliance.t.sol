// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {LBFactory} from "../src/LBFactory.sol";
import {LBPair} from "../src/LBPair.sol";
import {LBRouter} from "../src/LBRouter.sol";
import {ILBPairTypes} from "../src/interfaces/ILBPairTypes.sol";
import {RWAToken} from "../src/tokens/RWAToken.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {Identity} from "../src/compliance/Identity.sol";
import {ClaimIssuer} from "../src/compliance/ClaimIssuer.sol";
import {IdentityRegistry} from "../src/compliance/IdentityRegistry.sol";
import {ComplianceModule} from "../src/compliance/ComplianceModule.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title ComplianceTest
 * @notice Tests that compliance is enforced at the TOKEN level, not the DEX level.
 *
 * Architecture under test:
 * - LBPair is permissionless: anyone can swap/mint/burn.
 * - RWAToken (ERC-3643) enforces KYC inside transferFrom().
 * - If an unverified user triggers a swap, the token's transferFrom() reverts.
 * - Plain ERC-20 tokens (MockERC20) have no restrictions.
 *
 * Pairs used in tests:
 * - rwaPair: RWAToken (AMZN) / MockERC20 (WETH) — compliance on AMZN token
 * - plainPair: MockERC20 / MockERC20 — no compliance, fully open
 */
contract ComplianceTest is Test {
    // DEX
    LBFactory factory;
    LBRouter router;

    // Pairs
    LBPair rwaPair;    // RWAToken (amzn) / MockERC20 (weth)
    LBPair plainPair;  // MockERC20 / MockERC20

    // Tokens
    RWAToken amzn;     // Stock token with compliance
    MockERC20 weth;    // Plain token, no restrictions
    MockERC20 usdc;    // Plain token for plainPair

    // ERC-3643 compliance stack
    IdentityRegistry identityRegistry;
    ComplianceModule complianceModule;
    ClaimIssuer claimIssuer;

    // Identities
    Identity aliceIdentity;
    Identity bobIdentity;

    // Actors
    address owner = address(this);
    address kycProvider = address(0xBEEF);
    address alice = address(0xA11CE);  // KYC verified
    address bob = address(0xB0B);      // KYC verified
    address charlie = address(0xC0C0); // unverified

    uint256 constant KYC_TOPIC = 1;
    uint16 constant US = 840;
    uint16 constant UK = 826;

    uint16 binStep = 50;
    uint24 activeId = 8_388_608;

    // ---------------------------------------------------------------

    function setUp() public {
        // Deploy compliance stack
        identityRegistry = new IdentityRegistry(owner);
        complianceModule = new ComplianceModule(owner, address(identityRegistry));
        claimIssuer = new ClaimIssuer(kycProvider);

        uint256[] memory topics = new uint256[](1);
        topics[0] = KYC_TOPIC;
        identityRegistry.addTrustedIssuer(address(claimIssuer), topics);

        // Deploy DEX (no compliance module set — DEX is permissionless)
        LBPair implementation = new LBPair();
        LBFactory factoryImpl = new LBFactory();
        LBRouter routerImpl = new LBRouter();

        factory = LBFactory(address(new TransparentUpgradeableProxy(
            address(factoryImpl), owner,
            abi.encodeCall(LBFactory.initialize, (owner, owner, address(implementation)))
        )));
        router = LBRouter(address(new TransparentUpgradeableProxy(
            address(routerImpl), owner,
            abi.encodeCall(LBRouter.initialize, (address(factory)))
        )));

        // Deploy tokens
        amzn = new RWAToken("Amazon Stock Token", "AMZN", 18, owner);
        amzn.setComplianceModule(address(complianceModule));  // AMZN requires KYC

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 18);

        // Create pairs
        address rwaPairAddr = factory.createPair(address(amzn), address(weth), binStep, activeId);
        rwaPair = LBPair(rwaPairAddr);

        address plainPairAddr = factory.createPair(address(usdc), address(weth), binStep, activeId);
        plainPair = LBPair(plainPairAddr);

        // Register verified users
        _setupVerifiedUser(alice, US);
        _setupVerifiedUser(bob, UK);

        // Mint to all actors
        // AMZN: only mint to verified users (owner bypasses compliance via mint())
        amzn.mint(alice, 1_000_000e18);
        amzn.mint(bob, 1_000_000e18);
        amzn.mint(charlie, 1_000_000e18); // charlie holds AMZN but can't transfer it

        weth.mint(alice, 1_000_000e18);
        weth.mint(bob, 1_000_000e18);
        weth.mint(charlie, 1_000_000e18);
        usdc.mint(alice, 1_000_000e18);
        usdc.mint(charlie, 1_000_000e18);
    }

    // =============================================================
    //             DEX IS PERMISSIONLESS TESTS
    // =============================================================

    /// @notice Any wallet can add liquidity to a plain ERC-20 pair — no KYC needed.
    function testPlainPairIsFullyPermissionless() public {
        // Charlie (unverified) can add liquidity to plain pair
        _addLiquidityAsPlain(charlie);
        assertGt(plainPair.balanceOf(charlie, activeId), 0, "Charlie should have LP shares");
    }

    /// @notice Any wallet can swap on a plain ERC-20 pair — no KYC needed.
    function testUnverifiedUserCanSwapOnPlainPair() public {
        _addLiquidityAsPlain(alice);

        address pairTokenX = plainPair.tokenX();

        vm.startPrank(charlie);
        MockERC20(pairTokenX).approve(address(plainPair), type(uint256).max);
        ILBPairTypes.SwapResult memory result = plainPair.swap(ILBPairTypes.SwapParameters({
            swapForY: true,
            amountIn: 100e18,
            minAmountOut: 0,
            deadline: block.timestamp + 1 hours,
            to: charlie
        }));
        vm.stopPrank();

        assertGt(result.amountOut, 0, "Unverified user should swap freely on plain pair");
    }

    // =============================================================
    //             TOKEN-LEVEL COMPLIANCE TESTS (RWAToken)
    // =============================================================

    /// @notice Verified user can add liquidity with RWA token (transferFrom succeeds).
    function testVerifiedUserCanAddLiquidityToRwaPair() public {
        _addLiquidityAsRwa(alice);
        assertGt(rwaPair.balanceOf(alice, activeId), 0, "Alice should have LP shares");
    }

    /// @notice Unverified user's transferFrom on RWAToken reverts, blocking liquidity addition.
    function testUnverifiedUserCannotAddLiquidityToRwaPair() public {
        address pairTokenX = rwaPair.tokenX();
        address pairTokenY = rwaPair.tokenY();

        vm.startPrank(charlie);
        // Charlie approves both tokens
        RWAToken(pairTokenX).approve(address(rwaPair), type(uint256).max);
        MockERC20(pairTokenY).approve(address(rwaPair), type(uint256).max);

        uint24[] memory binIds = new uint24[](1);
        binIds[0] = activeId;
        uint64[] memory dist = new uint64[](1);
        dist[0] = 1e18;

        ILBPairTypes.LiquidityParameters memory params = ILBPairTypes.LiquidityParameters({
            binIds: binIds,
            distributionX: dist,
            distributionY: dist,
            amountX: 1_000e18,
            amountY: 1_000e18,
            activeIdDesired: activeId,
            idSlippage: 5,
            deadline: block.timestamp + 1 hours,
            to: charlie
        });

        // LBPair uses a low-level call for token transfers and wraps reverts as a string error.
        vm.expectRevert("LBPair: TRANSFER_FROM_FAILED");
        rwaPair.mint(params);
        vm.stopPrank();
    }

    /// @notice Verified user can swap on RWA pair.
    function testVerifiedUserCanSwapOnRwaPair() public {
        _addLiquidityAsRwa(alice);

        address pairTokenX = rwaPair.tokenX();

        vm.startPrank(bob);
        RWAToken(pairTokenX).approve(address(rwaPair), type(uint256).max);
        ILBPairTypes.SwapResult memory result = rwaPair.swap(ILBPairTypes.SwapParameters({
            swapForY: true,
            amountIn: 100e18,
            minAmountOut: 0,
            deadline: block.timestamp + 1 hours,
            to: bob
        }));
        vm.stopPrank();

        assertGt(result.amountOut, 0, "Bob (verified) should receive output");
    }

    /// @notice Unverified user's transferFrom on RWAToken reverts during swap.
    function testUnverifiedUserCannotSwapRwaToken() public {
        _addLiquidityAsRwa(alice);

        address pairTokenX = rwaPair.tokenX();

        vm.startPrank(charlie);
        RWAToken(pairTokenX).approve(address(rwaPair), type(uint256).max);

        // The revert comes from RWAToken (on input or output transfer) wrapped by LBPair.
        // The exact wrapper string depends on token sort order, so accept any revert.
        vm.expectRevert();
        rwaPair.swap(ILBPairTypes.SwapParameters({
            swapForY: true,
            amountIn: 100e18,
            minAmountOut: 0,
            deadline: block.timestamp + 1 hours,
            to: charlie
        }));
        vm.stopPrank();
    }

    // =============================================================
    //             RWAToken-SPECIFIC TESTS
    // =============================================================

    function testDirectRwaTransferBlockedForUnverified() public {
        vm.prank(charlie);
        vm.expectRevert(
            abi.encodeWithSignature("RWAToken__NotCompliant(address,address)", charlie, alice)
        );
        amzn.transfer(alice, 100e18);
    }

    function testDirectRwaTransferAllowedForVerified() public {
        uint256 beforeBal = amzn.balanceOf(bob);
        vm.prank(alice);
        amzn.transfer(bob, 100e18);
        assertEq(amzn.balanceOf(bob), beforeBal + 100e18);
    }

    function testClaimRevocationBlocksTransfer() public {
        // Revoke Alice's KYC claim
        bytes32 claimId = keccak256(abi.encodePacked(address(claimIssuer), KYC_TOPIC));
        vm.prank(kycProvider);
        claimIssuer.revokeClaim(claimId);

        assertFalse(identityRegistry.isVerified(alice), "Alice should be unverified after revocation");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("RWAToken__NotCompliant(address,address)", alice, bob)
        );
        amzn.transfer(bob, 100e18);
    }

    function testFreezeBlocksTransfer() public {
        amzn.freeze(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("RWAToken__AccountFrozen(address)", alice));
        amzn.transfer(bob, 100e18);
    }

    function testFreezeBlocksReceiving() public {
        amzn.freeze(bob);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("RWAToken__AccountFrozen(address)", bob));
        amzn.transfer(bob, 100e18);
    }

    function testUnfreezeRestoresTransfers() public {
        amzn.freeze(alice);
        amzn.unfreeze(alice);

        uint256 before = amzn.balanceOf(bob);
        vm.prank(alice);
        amzn.transfer(bob, 100e18);
        assertEq(amzn.balanceOf(bob), before + 100e18);
    }

    function testForcedTransferBypassesCompliance() public {
        // Charlie is unverified and frozen — forcedTransfer should still work
        amzn.freeze(charlie);

        uint256 charlieBalance = amzn.balanceOf(charlie);
        uint256 ownerBalance = amzn.balanceOf(owner);

        amzn.forcedTransfer(charlie, owner, charlieBalance);

        assertEq(amzn.balanceOf(charlie), 0);
        assertEq(amzn.balanceOf(owner), ownerBalance + charlieBalance);
    }

    function testMintBypassesCompliance() public {
        // Owner can mint to unverified/frozen charlie
        amzn.freeze(charlie);
        amzn.mint(charlie, 500e18);
        assertEq(amzn.balanceOf(charlie), 1_000_000e18 + 500e18);
    }

    function testRemoveComplianceModuleMakesTokenPermissionless() public {
        // Remove compliance module from AMZN
        amzn.setComplianceModule(address(0));

        // Charlie (unverified) can now transfer freely
        uint256 before = amzn.balanceOf(alice);
        vm.prank(charlie);
        amzn.transfer(alice, 100e18);
        assertEq(amzn.balanceOf(alice), before + 100e18);
    }

    // =============================================================
    //              IDENTITY & CLAIM TESTS
    // =============================================================

    function testIdentityCreation() public view {
        assertEq(identityRegistry.identity(alice), address(aliceIdentity));
        assertEq(identityRegistry.identity(bob), address(bobIdentity));
        assertEq(identityRegistry.identity(charlie), address(0));
    }

    function testCountryTracking() public view {
        assertEq(identityRegistry.investorCountry(alice), US);
        assertEq(identityRegistry.investorCountry(bob), UK);
    }

    function testVerificationStatus() public view {
        assertTrue(identityRegistry.isVerified(alice));
        assertTrue(identityRegistry.isVerified(bob));
        assertFalse(identityRegistry.isVerified(charlie));
    }

    function testDeleteIdentity() public {
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
    //              COMPLIANCE MODULE TESTS
    // =============================================================

    function testCountryRestriction() public {
        complianceModule.setCountryRestrictionsEnabled(address(amzn), true);
        complianceModule.setCountryAllowed(address(amzn), US, true);
        // UK NOT allowed

        // canTransfer checks the SENDER's country — alice (US, allowed) passes, bob (UK, blocked) fails.
        assertTrue(complianceModule.canTransfer(address(amzn), alice, alice, 100e18), "US sender should pass");
        assertFalse(complianceModule.canTransfer(address(amzn), bob, bob, 100e18), "UK sender should fail");
    }

    function testTransferLimits() public {
        complianceModule.setTransferLimits(address(amzn), 10_000e18, 100_000e18);

        assertTrue(complianceModule.canTransfer(address(amzn), alice, bob, 5_000e18));
        assertFalse(complianceModule.canTransfer(address(amzn), alice, bob, 15_000e18));
    }

    function testWhitelistedAddressBypassesCompliance() public {
        complianceModule.setWhitelisted(charlie, true);
        assertTrue(complianceModule.isVerified(charlie));
    }

    // =============================================================
    //                        HELPERS
    // =============================================================

    function _setupVerifiedUser(address user, uint16 country) internal {
        Identity id = new Identity(user);
        identityRegistry.registerIdentity(user, address(id), country);

        vm.prank(user);
        id.addClaim(
            KYC_TOPIC,
            0, // scheme 0 = trust-based
            address(claimIssuer),
            "",
            abi.encode(user, block.timestamp),
            ""
        );

        if (user == alice) aliceIdentity = id;
        else if (user == bob) bobIdentity = id;
    }

    function _addLiquidityAsRwa(address user) internal {
        address pairTokenX = rwaPair.tokenX(); // AMZN or WETH depending on sort
        address pairTokenY = rwaPair.tokenY();

        vm.startPrank(user);
        RWAToken(pairTokenX).approve(address(rwaPair), type(uint256).max);
        MockERC20(pairTokenY).approve(address(rwaPair), type(uint256).max);

        uint24[] memory binIds = new uint24[](1);
        binIds[0] = activeId;
        uint64[] memory dist = new uint64[](1);
        dist[0] = 1e18;

        rwaPair.mint(ILBPairTypes.LiquidityParameters({
            binIds: binIds,
            distributionX: dist,
            distributionY: dist,
            amountX: 10_000e18,
            amountY: 10_000e18,
            activeIdDesired: activeId,
            idSlippage: 5,
            deadline: block.timestamp + 1 hours,
            to: user
        }));
        vm.stopPrank();
    }

    function _addLiquidityAsPlain(address user) internal {
        address pairTokenX = plainPair.tokenX();
        address pairTokenY = plainPair.tokenY();

        vm.startPrank(user);
        MockERC20(pairTokenX).approve(address(plainPair), type(uint256).max);
        MockERC20(pairTokenY).approve(address(plainPair), type(uint256).max);

        uint24[] memory binIds = new uint24[](1);
        binIds[0] = activeId;
        uint64[] memory dist = new uint64[](1);
        dist[0] = 1e18;

        plainPair.mint(ILBPairTypes.LiquidityParameters({
            binIds: binIds,
            distributionX: dist,
            distributionY: dist,
            amountX: 10_000e18,
            amountY: 10_000e18,
            activeIdDesired: activeId,
            idSlippage: 5,
            deadline: block.timestamp + 1 hours,
            to: user
        }));
        vm.stopPrank();
    }
}
