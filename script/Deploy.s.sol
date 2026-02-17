// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/LBFactory.sol";
import "../src/LBRouter.sol";
import "../src/mocks/MockERC20.sol";
import "../src/compliance/IdentityRegistry.sol";
import "../src/compliance/ComplianceModule.sol";
import "../src/compliance/ClaimIssuer.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // --- Compliance Stack ---
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

        // --- DEX Core ---
        LBFactory factory = new LBFactory(deployer, deployer);
        factory.setComplianceModule(address(compliance));
        console.log("LBFactory:", address(factory));

        LBRouter router = new LBRouter(address(factory));
        console.log("LBRouter:", address(router));

        // Whitelist router in compliance
        compliance.setWhitelisted(address(router), true);

        // --- Mock Tokens ---
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 aapl = new MockERC20("Apple Stock Token", "AAPL", 18);
        MockERC20 tsla = new MockERC20("Tesla Stock Token", "TSLA", 18);
        MockERC20 msft = new MockERC20("Microsoft Stock Token", "MSFT", 18);
        console.log("USDC:", address(usdc));
        console.log("AAPL:", address(aapl));
        console.log("TSLA:", address(tsla));
        console.log("MSFT:", address(msft));

        // Mint to deployer
        usdc.mint(deployer, 1_000_000 * 1e6);
        aapl.mint(deployer, 1_000_000 * 1e18);
        tsla.mint(deployer, 1_000_000 * 1e18);
        msft.mint(deployer, 1_000_000 * 1e18);

        // --- Create Pairs ---
        address aaplUsdc = factory.createPair(address(aapl), address(usdc), 10, 8_388_608);
        address tslaUsdc = factory.createPair(address(tsla), address(usdc), 50, 8_388_608);
        address msftUsdc = factory.createPair(address(msft), address(usdc), 100, 8_388_608);
        console.log("AAPL/USDC (10bp):", aaplUsdc);
        console.log("TSLA/USDC (50bp):", tslaUsdc);
        console.log("MSFT/USDC (100bp):", msftUsdc);

        // Whitelist all pairs in compliance
        compliance.setWhitelisted(aaplUsdc, true);
        compliance.setWhitelisted(tslaUsdc, true);
        compliance.setWhitelisted(msftUsdc, true);

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
    }
}
