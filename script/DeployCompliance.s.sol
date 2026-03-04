// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/compliance/RWAToken.sol";
import "../src/compliance/IdentityRegistry.sol";
import "../src/compliance/ComplianceModule.sol";
import "../src/compliance/ClaimIssuer.sol";
import "../src/shared/mocks/MockERC20.sol";
import "../src/trading/infrastructure/LBFactory.sol";

/**
 * @notice Redeploy compliance stack + RWA tokens + pairs.
 *
 * Used after security hardening when compliance contracts (non-proxied) need fresh deployment.
 * Trading proxies (Factory, Router, Oracle) stay in place — only implementations are upgraded
 * separately via Upgrade.s.sol.
 *
 * Usage:
 *   source .env && \
 *   FACTORY_PROXY=0x3b6579a20C30Dc35aFab2737FD13D3bb5fFF0CFE \
 *   forge script script/DeployCompliance.s.sol --rpc-url robinhood_testnet --broadcast --slow
 */
contract DeployCompliance is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address factoryProxy = vm.envAddress("FACTORY_PROXY");

        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);
        console.log("Factory:", factoryProxy);

        LBFactory factory = LBFactory(factoryProxy);

        vm.startBroadcast(deployerPrivateKey);

        // ================================================================
        // 1. ERC-3643 Compliance Stack
        // ================================================================
        IdentityRegistry identityRegistry = new IdentityRegistry(deployer);
        console.log("IdentityRegistry:", address(identityRegistry));

        ComplianceModule compliance = new ComplianceModule(deployer, address(identityRegistry));
        console.log("ComplianceModule:", address(compliance));

        ClaimIssuer claimIssuer = new ClaimIssuer(deployer);
        console.log("ClaimIssuer:", address(claimIssuer));

        // Trust the claim issuer for KYC (topic 1)
        uint256[] memory topics = new uint256[](1);
        topics[0] = 1;
        identityRegistry.addTrustedIssuer(address(claimIssuer), topics);

        // ================================================================
        // 2. Deploy tokens
        // ================================================================
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        console.log("USDC:", address(usdc));
        usdc.mint(deployer, 1_000_000 * 1e6);

        RWAToken aapl = new RWAToken("Apple Stock Token", "AAPL", 18, deployer);
        aapl.setComplianceModule(address(compliance));
        console.log("AAPL:", address(aapl));

        RWAToken tsla = new RWAToken("Tesla Stock Token", "TSLA", 18, deployer);
        tsla.setComplianceModule(address(compliance));
        console.log("TSLA:", address(tsla));

        RWAToken msft = new RWAToken("Microsoft Stock Token", "MSFT", 18, deployer);
        msft.setComplianceModule(address(compliance));
        console.log("MSFT:", address(msft));

        // ================================================================
        // 3. Authorize RWA tokens to record transfers in ComplianceModule
        // ================================================================
        compliance.setAuthorizedToken(address(aapl), true);
        compliance.setAuthorizedToken(address(tsla), true);
        compliance.setAuthorizedToken(address(msft), true);

        // ================================================================
        // 4. Mint initial supply
        // ================================================================
        aapl.mint(deployer, 1_000_000e18);
        tsla.mint(deployer, 1_000_000e18);
        msft.mint(deployer, 1_000_000e18);

        // ================================================================
        // 5. Create pairs via existing factory
        // ================================================================
        address aaplUsdc = factory.createPair(address(aapl), address(usdc), 10, 8_388_608);
        address tslaUsdc = factory.createPair(address(tsla), address(usdc), 50, 8_388_608);
        address msftUsdc = factory.createPair(address(msft), address(usdc), 100, 8_388_608);
        console.log("AAPL/USDC (10bp):", aaplUsdc);
        console.log("TSLA/USDC (50bp):", tslaUsdc);
        console.log("MSFT/USDC (100bp):", msftUsdc);

        // ================================================================
        // 6. Whitelist pairs in compliance (so pairs can hold RWA tokens)
        // ================================================================
        compliance.setWhitelisted(aaplUsdc, true);
        compliance.setWhitelisted(tslaUsdc, true);
        compliance.setWhitelisted(msftUsdc, true);

        vm.stopBroadcast();

        console.log("\n=== Compliance Redeploy Complete ===");
        console.log("Register user identities via IdentityRegistry before trading.");
        console.log("Use ClaimIssuer to issue ECDSA-signed KYC claims (scheme 1 only).");
    }
}
