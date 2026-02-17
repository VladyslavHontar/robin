// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/LBFactory.sol";
import "../src/LBRouter.sol";
import "../src/mocks/MockERC20.sol";

/**
 * @title Deploy
 * @notice Deployment script for Robinhood Chain testnet
 * @dev Deploys factory, router, and creates mock token pairs
 *
 * Usage:
 * forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
 */
contract Deploy is Script {
    // Deployment addresses will be saved here
    LBFactory public factory;
    LBRouter public router;
    MockERC20 public usdc;
    MockERC20 public aapl; // Mock Apple stock token
    MockERC20 public tsla; // Mock Tesla stock token
    MockERC20 public msft; // Mock Microsoft stock token

    function run() external {
        // Get deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying with address:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Factory
        console.log("\n=== Deploying Factory ===");
        factory = new LBFactory(deployer, deployer); // owner = deployer, feeRecipient = deployer
        console.log("Factory deployed at:", address(factory));

        // 2. Deploy Router
        console.log("\n=== Deploying Router ===");
        router = new LBRouter(address(factory));
        console.log("Router deployed at:", address(router));

        // 3. Deploy Mock Tokens
        console.log("\n=== Deploying Mock Tokens ===");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        console.log("USDC deployed at:", address(usdc));

        aapl = new MockERC20("Apple Stock Token", "AAPL", 18);
        console.log("AAPL deployed at:", address(aapl));

        tsla = new MockERC20("Tesla Stock Token", "TSLA", 18);
        console.log("TSLA deployed at:", address(tsla));

        msft = new MockERC20("Microsoft Stock Token", "MSFT", 18);
        console.log("MSFT deployed at:", address(msft));

        // 4. Mint tokens to deployer
        console.log("\n=== Minting Test Tokens ===");
        uint256 mintAmount = 1_000_000 * 1e18; // 1M tokens

        usdc.mint(deployer, mintAmount / 1e12); // Adjust for 6 decimals
        aapl.mint(deployer, mintAmount);
        tsla.mint(deployer, mintAmount);
        msft.mint(deployer, mintAmount);

        console.log("Minted tokens to deployer");

        // 5. Create pairs with different bin steps
        console.log("\n=== Creating Pairs ===");

        // AAPL/USDC with 10bp (ultra-tight for blue chip)
        address aaplUsdc10 = factory.createPair(
            address(aapl),
            address(usdc),
            10, // 0.1% bin step
            8_388_608 // Initial bin ID (middle)
        );
        console.log("AAPL/USDC (10bp) pair:", aaplUsdc10);

        // TSLA/USDC with 50bp (standard)
        address tslaUsdc50 = factory.createPair(
            address(tsla),
            address(usdc),
            50, // 0.5% bin step
            8_388_608
        );
        console.log("TSLA/USDC (50bp) pair:", tslaUsdc50);

        // MSFT/USDC with 100bp (wide)
        address msftUsdc100 = factory.createPair(
            address(msft),
            address(usdc),
            100, // 1% bin step
            8_388_608
        );
        console.log("MSFT/USDC (100bp) pair:", msftUsdc100);

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== Deployment Summary ===");
        console.log("Factory:", address(factory));
        console.log("Router:", address(router));
        console.log("USDC:", address(usdc));
        console.log("AAPL:", address(aapl));
        console.log("TSLA:", address(tsla));
        console.log("MSFT:", address(msft));
        console.log("\nPairs:");
        console.log("AAPL/USDC (10bp):", aaplUsdc10);
        console.log("TSLA/USDC (50bp):", tslaUsdc50);
        console.log("MSFT/USDC (100bp):", msftUsdc100);
        console.log("\n[OK] Deployment complete!");
    }
}
