// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Script, console2 } from "forge-std/Script.sol";

import { CvmCoordinator } from "@src/oracle/CvmCoordinator.sol";

import { OracleDeployment } from "../utils/OracleDeployment.sol";
import { ProxyUtils } from "../utils/ProxyUtils.sol";

/**
 * @title UpgradeCvmCoordinator
 * @notice Deploy a new CvmCoordinator implementation, upgrade the proxy from
 *         `deployments/base-sepolia-oracle.json`, and write `cvmCoordinatorImpl`.
 * @dev Env: PRIVATE_KEY (must own ProxyAdmin).
 *      Makefile: `make upgrade-base-sepolia-cvm-coordinator`
 */
contract UpgradeCvmCoordinator is Script, ProxyUtils, OracleDeployment {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        string memory json = _readOracleDeployment();
        address proxy = _oracleCoordinator(json);

        vm.startBroadcast(privateKey);
        CvmCoordinator impl = new CvmCoordinator();
        _upgradeAndCall(proxy, address(impl), "");
        vm.stopBroadcast();

        _writeOracleImpl("cvmCoordinatorImpl", address(impl));

        console2.log("Upgraded CvmCoordinator proxy", proxy);
        console2.log("New impl", address(impl));
        console2.log("Updated", ORACLE_DEPLOYMENT_PATH);
    }
}
