pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/trading/infrastructure/LBFactory.sol";
import "../src/trading/domain/LBPair.sol";
import "../src/trading/application/LBRouter.sol";
import "../src/trading/infrastructure/OracleModule.sol";
import {ITransparentUpgradeableProxy} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC1967Utils} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";

/**
 * @notice Upgrade script for singleton contracts behind TransparentUpgradeableProxy.
 *
 * Deploys new implementation contracts and upgrades the proxies via ProxyAdmin.
 * Proxy addresses remain unchanged — state is fully preserved.
 *
 * Usage:
 *   FACTORY_PROXY=0x... ROUTER_PROXY=0x... ORACLE_PROXY=0x... \
 *   forge script script/Upgrade.s.sol --rpc-url <RPC> --broadcast --slow --gas-estimate-multiplier 150
 *
 * Set env vars for which contracts to upgrade:
 *   UPGRADE_FACTORY=true   (default: false)
 *   UPGRADE_ROUTER=true    (default: false)
 *   UPGRADE_ORACLE=true    (default: false)
 *   UPGRADE_PAIR=true      (default: false — upgrades via beacon, not proxy)
 */
contract Upgrade is Script {
    /// @dev ERC-1967 admin slot: keccak256("eip1967.proxy.admin") - 1
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Upgrader:", deployer);

        // Read proxy addresses from env
        address factoryProxy = vm.envAddress("FACTORY_PROXY");
        address routerProxy = vm.envAddress("ROUTER_PROXY");
        address oracleProxy = vm.envAddress("ORACLE_PROXY");

        bool upgradeFactory = vm.envOr("UPGRADE_FACTORY", false);
        bool upgradeRouter = vm.envOr("UPGRADE_ROUTER", false);
        bool upgradeOracle = vm.envOr("UPGRADE_ORACLE", false);
        bool upgradePair = vm.envOr("UPGRADE_PAIR", false);

        console.log("Factory Proxy:", factoryProxy);
        console.log("Router Proxy:", routerProxy);
        console.log("Oracle Proxy:", oracleProxy);

        vm.startBroadcast(deployerPrivateKey);

        if (upgradeFactory) {
            LBFactory newFactoryImpl = new LBFactory();
            console.log("New LBFactory Implementation:", address(newFactoryImpl));

            address admin = _getProxyAdmin(factoryProxy);
            console.log("Factory ProxyAdmin:", admin);

            ProxyAdmin(admin).upgradeAndCall(
                ITransparentUpgradeableProxy(factoryProxy),
                address(newFactoryImpl),
                ""
            );
            console.log("LBFactory upgraded");
        }

        if (upgradeRouter) {
            LBRouter newRouterImpl = new LBRouter();
            console.log("New LBRouter Implementation:", address(newRouterImpl));

            address admin = _getProxyAdmin(routerProxy);
            console.log("Router ProxyAdmin:", admin);

            ProxyAdmin(admin).upgradeAndCall(
                ITransparentUpgradeableProxy(routerProxy),
                address(newRouterImpl),
                ""
            );
            console.log("LBRouter upgraded");
        }

        if (upgradeOracle) {
            OracleModule newOracleImpl = new OracleModule();
            console.log("New OracleModule Implementation:", address(newOracleImpl));

            address admin = _getProxyAdmin(oracleProxy);
            console.log("Oracle ProxyAdmin:", admin);

            ProxyAdmin(admin).upgradeAndCall(
                ITransparentUpgradeableProxy(oracleProxy),
                address(newOracleImpl),
                ""
            );
            console.log("OracleModule upgraded");
        }

        if (upgradePair) {
            LBPair newPairImpl = new LBPair();
            console.log("New LBPair Implementation:", address(newPairImpl));

            // Pair upgrades go through the factory beacon, not ProxyAdmin
            LBFactory(factoryProxy).upgradePairImplementation(address(newPairImpl));
            console.log("LBPair beacon upgraded (all pairs updated)");
        }

        vm.stopBroadcast();
        console.log("\n=== Upgrade Complete ===");
        console.log("Proxy addresses unchanged. State preserved.");
    }

    function _getProxyAdmin(address proxy) internal view returns (address) {
        bytes32 value = vm.load(proxy, ADMIN_SLOT);
        return address(uint160(uint256(value)));
    }
}
