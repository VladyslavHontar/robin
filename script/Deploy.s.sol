// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/LBFactory.sol";
import "../src/LBPair.sol";
import "../src/LBRouter.sol";
import "../src/tokens/RWAToken.sol";
import "../src/mocks/MockERC20.sol";
import "../src/compliance/IdentityRegistry.sol";
import "../src/compliance/ComplianceModule.sol";
import "../src/compliance/ClaimIssuer.sol";
import "../src/OracleModule.sol";

/**
 * @notice Full deployment script for development / initial testnet setup.
 *
 * Architecture:
 * - DEX (LBFactory, LBRouter, LBPair) is permissionless — no compliance at DEX level.
 * - Stock tokens are RWAToken (ERC-3643): compliance enforced inside transferFrom().
 * - Non-security tokens (USDC, WETH) are plain MockERC20.
 * - The ERC-3643 compliance stack (IdentityRegistry, ComplianceModule, ClaimIssuer)
 *   is wired to each RWAToken, not to the DEX.
 */
contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // --- ERC-3643 Compliance Stack ---
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

        // --- DEX Core (permissionless — no compliance module attached) ---
        // Deploy the LBPair implementation first; the factory wraps it in a beacon.
        // All pair proxies can be upgraded later via factory.upgradePairImplementation().
        LBPair pairImpl = new LBPair();
        console.log("LBPair Implementation:", address(pairImpl));

        LBFactory factory = new LBFactory(deployer, deployer, address(pairImpl));
        console.log("LBFactory:", address(factory));

        LBRouter router = new LBRouter(address(factory));
        console.log("LBRouter:", address(router));

        // --- Plain Token: USDC (not an RWA, no compliance needed) ---
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        console.log("USDC:", address(usdc));
        usdc.mint(deployer, 1_000_000 * 1e6);

        // --- RWA Stock Tokens (ERC-3643, compliance enforced at token level) ---
        RWAToken aapl = new RWAToken("Apple Stock Token", "AAPL", 18, deployer);
        aapl.setComplianceModule(address(compliance));
        console.log("AAPL:", address(aapl));
        aapl.mint(deployer, 1_000_000e18);

        RWAToken tsla = new RWAToken("Tesla Stock Token", "TSLA", 18, deployer);
        tsla.setComplianceModule(address(compliance));
        console.log("TSLA:", address(tsla));
        tsla.mint(deployer, 1_000_000e18);

        RWAToken msft = new RWAToken("Microsoft Stock Token", "MSFT", 18, deployer);
        msft.setComplianceModule(address(compliance));
        console.log("MSFT:", address(msft));
        msft.mint(deployer, 1_000_000e18);

        // --- Oracle Module ---
        OracleModule oracleModule = new OracleModule(deployer);
        console.log("OracleModule:", address(oracleModule));

        // Wire oracle module to factory (auto-set on new pairs)
        factory.setOracleModule(address(oracleModule));

        // --- Create Pairs ---
        address aaplUsdc = factory.createPair(address(aapl), address(usdc), 10, 8_388_608);
        address tslaUsdc = factory.createPair(address(tsla), address(usdc), 50, 8_388_608);
        address msftUsdc = factory.createPair(address(msft), address(usdc), 100, 8_388_608);
        console.log("AAPL/USDC (10bp):", aaplUsdc);
        console.log("TSLA/USDC (50bp):", tslaUsdc);
        console.log("MSFT/USDC (100bp):", msftUsdc);

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log("Register user identities via IdentityRegistry before trading RWA tokens.");
        console.log("Configure Chainlink price feeds via OracleModule.setPriceFeed().");
    }
}
