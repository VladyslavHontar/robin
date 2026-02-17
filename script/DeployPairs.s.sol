// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/LBFactory.sol";
import "../src/WETH.sol";
import "../src/compliance/ComplianceModule.sol";

contract DeployPairs is Script {
    // Existing deployed contracts
    address constant FACTORY = 0x30f8819710611d80Ce22d57947223F33C2fe8C9E;
    address constant COMPLIANCE = 0xEFb56C901723c03DcddC8Bf38e2737d58D71c26B;

    // Real Robinhood testnet tokens
    address constant AMZN = 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02;
    address constant AMD  = 0x71178BAc73cBeb415514eB542a8995b82669778d;
    address constant NFLX = 0x3b8262A63d25f0477c4DDE23F83cfe22Cb768C93;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy WETH
        WETH weth = new WETH();
        console.log("WETH:", address(weth));

        LBFactory factory = LBFactory(FACTORY);
        ComplianceModule compliance = ComplianceModule(COMPLIANCE);

        // Create pairs: token/WETH with 50bp bin step
        address amznWeth = factory.createPair(AMZN, address(weth), 50, 8_388_608);
        console.log("AMZN/WETH (50bp):", amznWeth);

        address amdWeth = factory.createPair(AMD, address(weth), 50, 8_388_608);
        console.log("AMD/WETH (50bp):", amdWeth);

        address nflxWeth = factory.createPair(NFLX, address(weth), 50, 8_388_608);
        console.log("NFLX/WETH (50bp):", nflxWeth);

        // Whitelist new pairs in compliance
        compliance.setWhitelisted(amznWeth, true);
        compliance.setWhitelisted(amdWeth, true);
        compliance.setWhitelisted(nflxWeth, true);

        vm.stopBroadcast();

        console.log("\n=== Done ===");
    }
}
