pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/trading/infrastructure/LBFactory.sol";
import "../src/trading/domain/LBPair.sol";
import "../src/trading/application/LBRouter.sol";
import "../src/compliance/RWAToken.sol";
import "../src/shared/mocks/MockERC20.sol";
import "../src/compliance/IdentityRegistry.sol";
import "../src/compliance/ComplianceModule.sol";
import "../src/compliance/ClaimIssuer.sol";
import "../src/trading/infrastructure/OracleModule.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @notice Full deployment script for development / initial testnet setup.
 *
 * Architecture:
 * - Singleton contracts (LBFactory, LBRouter, OracleModule) are deployed behind
 *   TransparentUpgradeableProxy via CREATE2 with fixed salts. This gives
 *   deterministic, permanent proxy addresses that survive implementation upgrades.
 * - LBPair instances use BeaconProxy (managed by the factory's beacon).
 * - Stock tokens are RWAToken (ERC-3643): compliance enforced inside transferFrom().
 * - Non-security tokens (USDC, WETH) are plain MockERC20.
 */
contract Deploy is Script {
    // Fixed salts for deterministic proxy addresses
    bytes32 constant FACTORY_SALT = keccak256("robin.factory.v1");
    bytes32 constant ROUTER_SALT  = keccak256("robin.router.v1");
    bytes32 constant ORACLE_SALT  = keccak256("robin.oracle.v1");

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // ================================================================
        // 1. ERC-3643 Compliance Stack (not proxied)
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
        // 2. Deploy implementations (logic contracts)
        // ================================================================
        LBPair pairImpl = new LBPair();
        console.log("LBPair Implementation:", address(pairImpl));

        LBFactory factoryImpl = new LBFactory();
        console.log("LBFactory Implementation:", address(factoryImpl));

        LBRouter routerImpl = new LBRouter();
        console.log("LBRouter Implementation:", address(routerImpl));

        OracleModule oracleImpl = new OracleModule();
        console.log("OracleModule Implementation:", address(oracleImpl));

        // ================================================================
        // 3. Deploy proxies via CREATE2 (deterministic addresses)
        // ================================================================

        // Factory proxy — initialized with owner, fee recipient, and pair implementation
        LBFactory factory = LBFactory(address(
            new TransparentUpgradeableProxy{salt: FACTORY_SALT}(
                address(factoryImpl),
                deployer,
                abi.encodeCall(LBFactory.initialize, (deployer, deployer, address(pairImpl)))
            )
        ));
        console.log("LBFactory Proxy:", address(factory));

        // OracleModule proxy — initialized with owner
        OracleModule oracleModule = OracleModule(address(
            new TransparentUpgradeableProxy{salt: ORACLE_SALT}(
                address(oracleImpl),
                deployer,
                abi.encodeCall(OracleModule.initialize, (deployer))
            )
        ));
        console.log("OracleModule Proxy:", address(oracleModule));

        // Router proxy — initialized with factory proxy address
        LBRouter router = LBRouter(address(
            new TransparentUpgradeableProxy{salt: ROUTER_SALT}(
                address(routerImpl),
                deployer,
                abi.encodeCall(LBRouter.initialize, (address(factory)))
            )
        ));
        console.log("LBRouter Proxy:", address(router));

        // ================================================================
        // 4. Wire oracle module to factory
        // ================================================================
        factory.setOracleModule(address(oracleModule));

        // ================================================================
        // 5. Deploy tokens
        // ================================================================

        // Plain token: USDC (not an RWA, no compliance needed)
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        console.log("USDC:", address(usdc));
        usdc.mint(deployer, 1_000_000 * 1e6);

        // RWA Stock Tokens (ERC-3643, compliance enforced at token level)
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

        // ================================================================
        // 6. Create pairs
        // ================================================================
        address aaplUsdc = factory.createPair(address(aapl), address(usdc), 10, 8_388_608);
        address tslaUsdc = factory.createPair(address(tsla), address(usdc), 50, 8_388_608);
        address msftUsdc = factory.createPair(address(msft), address(usdc), 100, 8_388_608);
        console.log("AAPL/USDC (10bp):", aaplUsdc);
        console.log("TSLA/USDC (50bp):", tslaUsdc);
        console.log("MSFT/USDC (100bp):", msftUsdc);

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log("Proxy addresses are deterministic and permanent.");
        console.log("Use Upgrade.s.sol to upgrade implementations without changing addresses.");
        console.log("Register user identities via IdentityRegistry before trading RWA tokens.");
        console.log("Configure Chainlink price feeds via OracleModule.setPriceFeed().");
    }
}
