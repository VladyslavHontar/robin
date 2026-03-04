// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {LBFactory} from "../src/trading/infrastructure/LBFactory.sol";
import {LBPair} from "../src/trading/domain/LBPair.sol";
import {LBRouter} from "../src/trading/application/LBRouter.sol";
import {ILBPairTypes} from "../src/trading/domain/kernel/ILBPairTypes.sol";
import {ILBPairErrors} from "../src/trading/domain/kernel/ILBPairErrors.sol";
import {RWAToken} from "../src/compliance/RWAToken.sol";
import {MockERC20} from "../src/shared/mocks/MockERC20.sol";
import {Identity} from "../src/compliance/Identity.sol";
import {ClaimIssuer} from "../src/compliance/ClaimIssuer.sol";
import {IdentityRegistry} from "../src/compliance/IdentityRegistry.sol";
import {ComplianceModule} from "../src/compliance/ComplianceModule.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title ComplianceTest
 * @notice Tests that compliance is enforced at the TOKEN level, not the DEX level.
 */
contract ComplianceTest is Test {
    // DEX
    LBFactory factory;
    LBRouter router;

    // Pairs
    LBPair rwaPair;
    LBPair plainPair;

    // Tokens
    RWAToken amzn;
    MockERC20 weth;
    MockERC20 usdc;

    // ERC-3643 compliance stack
    IdentityRegistry identityRegistry;
    ComplianceModule complianceModule;
    ClaimIssuer claimIssuer;

    // Identities
    Identity aliceIdentity;
    Identity bobIdentity;

    // Actors
    address owner = address(this);
    // Use vm private keys for ECDSA signing
    uint256 constant KYC_PROVIDER_KEY = 0xBEEF;
    address kycProvider;
    uint256 constant ALICE_KEY = 0xA11CE;
    address alice;
    uint256 constant BOB_KEY = 0xB0B;
    address bob;
    address charlie = address(0xC0C0); // unverified

    uint256 constant KYC_TOPIC = 1;
    uint16 constant US = 840;
    uint16 constant UK = 826;

    uint16 binStep = 50;
    uint24 activeId = 8_388_608;

    function setUp() public {
        // Derive addresses from private keys
        kycProvider = vm.addr(KYC_PROVIDER_KEY);
        alice = vm.addr(ALICE_KEY);
        bob = vm.addr(BOB_KEY);

        // Deploy compliance stack
        identityRegistry = new IdentityRegistry(owner);
        complianceModule = new ComplianceModule(owner, address(identityRegistry));
        claimIssuer = new ClaimIssuer(kycProvider);

        // Add kycProvider as signing key (constructor already does this)
        uint256[] memory topics = new uint256[](1);
        topics[0] = KYC_TOPIC;
        identityRegistry.addTrustedIssuer(address(claimIssuer), topics);

        // Deploy DEX
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
        amzn.setComplianceModule(address(complianceModule));

        // Authorize AMZN token to call recordTransfer on ComplianceModule
        complianceModule.setAuthorizedToken(address(amzn), true);

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 18);

        // Create pairs
        address rwaPairAddr = factory.createPair(address(amzn), address(weth), binStep, activeId);
        rwaPair = LBPair(rwaPairAddr);

        address plainPairAddr = factory.createPair(address(usdc), address(weth), binStep, activeId);
        plainPair = LBPair(plainPairAddr);

        // Whitelist the LBPair so it passes canTransfer for RWA tokens
        complianceModule.setWhitelisted(address(rwaPair), true);

        // Register verified users with ECDSA claims
        _setupVerifiedUser(alice, ALICE_KEY, US);
        _setupVerifiedUser(bob, BOB_KEY, UK);

        // Mint to all actors
        amzn.mint(alice, 1_000_000e18);
        amzn.mint(bob, 1_000_000e18);
        amzn.mint(charlie, 1_000_000e18);

        weth.mint(alice, 1_000_000e18);
        weth.mint(bob, 1_000_000e18);
        weth.mint(charlie, 1_000_000e18);
        usdc.mint(alice, 1_000_000e18);
        usdc.mint(charlie, 1_000_000e18);
    }

    // =============================================================
    //             DEX IS PERMISSIONLESS TESTS
    // =============================================================

    function testPlainPairIsFullyPermissionless() public {
        _addLiquidityAsPlain(charlie);
        assertGt(plainPair.balanceOf(charlie, activeId), 0, "Charlie should have LP shares");
    }

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

    function testVerifiedUserCanAddLiquidityToRwaPair() public {
        _addLiquidityAsRwa(alice);
        assertGt(rwaPair.balanceOf(alice, activeId), 0, "Alice should have LP shares");
    }

    function testUnverifiedUserCannotAddLiquidityToRwaPair() public {
        address pairTokenX = rwaPair.tokenX();
        address pairTokenY = rwaPair.tokenY();

        vm.startPrank(charlie);
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

        vm.expectRevert(ILBPairErrors.LBPair__TransferFailed.selector);
        rwaPair.mint(params);
        vm.stopPrank();
    }

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

    function testUnverifiedUserCannotSwapRwaToken() public {
        _addLiquidityAsRwa(alice);

        address pairTokenX = rwaPair.tokenX();

        vm.startPrank(charlie);
        RWAToken(pairTokenX).approve(address(rwaPair), type(uint256).max);

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

    function testForcedTransferRequiresFrozen() public {
        // Cannot force-transfer from unfrozen account
        vm.expectRevert(
            abi.encodeWithSignature("RWAToken__AccountNotFrozen(address)", charlie)
        );
        amzn.forcedTransfer(charlie, owner, 100e18);
    }

    function testForcedTransferBypassesCompliance() public {
        amzn.freeze(charlie);

        uint256 charlieBalance = amzn.balanceOf(charlie);
        uint256 ownerBalance = amzn.balanceOf(owner);

        amzn.forcedTransfer(charlie, owner, charlieBalance);

        assertEq(amzn.balanceOf(charlie), 0);
        assertEq(amzn.balanceOf(owner), ownerBalance + charlieBalance);
    }

    function testMintBypassesCompliance() public {
        amzn.freeze(charlie);
        amzn.mint(charlie, 500e18);
        assertEq(amzn.balanceOf(charlie), 1_000_000e18 + 500e18);
    }

    function testRemoveComplianceModuleMakesTokenPermissionless() public {
        amzn.setComplianceModule(address(0));

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

    function testAddClaimOnlyOwner() public {
        // Non-owner (even the issuer) cannot add claims
        vm.prank(kycProvider);
        vm.expectRevert(Identity.Identity__Unauthorized.selector);
        aliceIdentity.addClaim(KYC_TOPIC, 1, address(claimIssuer), "", "", "");
    }

    // =============================================================
    //              COMPLIANCE MODULE TESTS
    // =============================================================

    function testCountryRestriction() public {
        complianceModule.setCountryRestrictionsEnabled(address(amzn), true);
        complianceModule.setCountryAllowed(address(amzn), US, true);

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

    function testRecordTransferOnlyAuthorizedToken() public {
        // Unauthorized caller cannot record transfers
        vm.prank(charlie);
        vm.expectRevert(ComplianceModule.ComplianceModule__Unauthorized.selector);
        complianceModule.recordTransfer(address(amzn), alice, 100e18);
    }

    function testBatchArrayLengthMismatch() public {
        uint16[] memory countries = new uint16[](2);
        countries[0] = US;
        countries[1] = UK;
        bool[] memory allowed = new bool[](1);
        allowed[0] = true;

        vm.expectRevert(ComplianceModule.ComplianceModule__ArrayLengthMismatch.selector);
        complianceModule.batchSetCountryAllowed(address(amzn), countries, allowed);
    }

    // =============================================================
    //              TWO-STEP OWNERSHIP TESTS
    // =============================================================

    function testTwoStepOwnershipRWAToken() public {
        amzn.transferOwnership(alice);
        assertEq(amzn.owner(), owner); // unchanged
        vm.prank(alice);
        amzn.acceptOwnership();
        assertEq(amzn.owner(), alice);
    }

    function testTwoStepOwnershipComplianceModule() public {
        complianceModule.transferOwnership(alice);
        assertEq(complianceModule.owner(), owner);
        vm.prank(alice);
        complianceModule.acceptOwnership();
        assertEq(complianceModule.owner(), alice);
    }

    function testTwoStepOwnershipIdentityRegistry() public {
        identityRegistry.transferOwnership(alice);
        assertEq(identityRegistry.owner(), owner);
        vm.prank(alice);
        identityRegistry.acceptOwnership();
        assertEq(identityRegistry.owner(), alice);
    }

    function testTwoStepOwnershipClaimIssuer() public {
        vm.prank(kycProvider);
        claimIssuer.transferOwnership(alice);
        assertEq(claimIssuer.owner(), kycProvider);
        vm.prank(alice);
        claimIssuer.acceptOwnership();
        assertEq(claimIssuer.owner(), alice);
    }

    // =============================================================
    //                        HELPERS
    // =============================================================

    function _setupVerifiedUser(address user, uint256 userKey, uint16 country) internal {
        Identity id = new Identity(user);
        identityRegistry.registerIdentity(user, address(id), country);

        // Build ECDSA-signed claim (scheme 1)
        bytes32 claimId = keccak256(abi.encodePacked(address(claimIssuer), KYC_TOPIC));
        bytes memory claimData = abi.encode(user, block.timestamp);

        // Sign: hash(identityAddr, claimId, data) -> ethSignedMessage -> sign with kycProvider key
        bytes32 dataHash = keccak256(abi.encodePacked(address(id), claimId, claimData));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KYC_PROVIDER_KEY, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Identity owner adds the claim
        vm.prank(user);
        id.addClaim(
            KYC_TOPIC,
            1, // scheme 1 = ECDSA
            address(claimIssuer),
            signature,
            claimData,
            ""
        );

        if (user == alice) aliceIdentity = id;
        else if (user == bob) bobIdentity = id;
    }

    function _addLiquidityAsRwa(address user) internal {
        address pairTokenX = rwaPair.tokenX();
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
