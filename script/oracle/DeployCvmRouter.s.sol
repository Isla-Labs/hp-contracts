// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Script, console2 } from "forge-std/Script.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { CvmRouter } from "@src/oracle/CvmRouter.sol";
import { CvmRouterConfig } from "@types/oracle/CvmTypes.sol";

import { OracleDeployment } from "../utils/OracleDeployment.sol";
import { ProxyUtils } from "../utils/ProxyUtils.sol";

/**
 * @title DeployCvmRouter
 * @notice Deploy a **new** upgradeable CvmRouter proxy (rare). Prefer
 *         `UpgradeCvmRouter` for logic upgrades against the stable proxy.
 * @dev Env: PRIVATE_KEY, optional DAO_ADDRESS / CONSTITUTIONAL_ADDRESS.
 *      Coordinator is read from `deployments/base-sepolia-oracle.json`.
 *      After deploy, updates that file's `cvmRouter` + `cvmRouterImpl`.
 */
contract DeployCvmRouter is Script, ProxyUtils, OracleDeployment {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address dao = vm.envOr("DAO_ADDRESS", deployer);
        address constitutional = vm.envOr("CONSTITUTIONAL_ADDRESS", deployer);

        string memory json = _readOracleDeployment();
        address coordinator = _oracleCoordinator(json);

        CvmRouterConfig memory routerConfig = CvmRouterConfig({
            maxCallbackGasLimit: 5_000_000,
            requestTimeout: uint32(1 hours),
            gasForCallExactCheck: 5000
        });

        vm.startBroadcast(privateKey);
        InitGuard guard = new InitGuard();
        CvmRouter impl = new CvmRouter();
        address proxy = _deployInitGuardProxy(guard, dao);
        _upgradeAndCall(
            proxy,
            address(impl),
            abi.encodeCall(CvmRouter.initialize, (dao, constitutional, coordinator, routerConfig))
        );
        vm.stopBroadcast();

        // Fresh initialize already seeds exclusives; persist addresses.
        vm.writeJson(string.concat('"', vm.toString(proxy), '"'), ORACLE_DEPLOYMENT_PATH, ".cvmRouter");
        _writeOracleImpl("cvmRouterImpl", address(impl));

        console2.log("CvmRouter proxy", proxy);
        console2.log("CvmRouter impl", address(impl));
        console2.log("CvmCoordinator", coordinator);
        console2.log("Updated", ORACLE_DEPLOYMENT_PATH);
    }
}
