// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Script, console2 } from "forge-std/Script.sol";

import { CvmRouter } from "@src/oracle/CvmRouter.sol";

import { OracleDeployment } from "../utils/OracleDeployment.sol";
import { ProxyUtils } from "../utils/ProxyUtils.sol";

/**
 * @title UpgradeCvmRouter
 * @notice Deploy a new CvmRouter implementation, upgrade the proxy from
 *         `deployments/base-sepolia-oracle.json`, seed per-job exclusives, and
 *         write `cvmRouterImpl` back to that file.
 * @dev Env: PRIVATE_KEY (must own ProxyAdmin; typically also Ownable owner for seed).
 *      Makefile: `make upgrade-base-sepolia-cvm-router`
 */
contract UpgradeCvmRouter is Script, ProxyUtils, OracleDeployment {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        string memory json = _readOracleDeployment();
        address proxy = _oracleRouter(json);

        vm.startBroadcast(privateKey);
        CvmRouter impl = new CvmRouter();
        _upgradeAndCall(proxy, address(impl), "");
        // upgradeAndCall is admin-scoped; seed as the broadcaster (owner / deployer).
        CvmRouter(proxy).seedDefaultJobExclusives();
        vm.stopBroadcast();

        _writeOracleImpl("cvmRouterImpl", address(impl));

        console2.log("Upgraded CvmRouter proxy", proxy);
        console2.log("New impl", address(impl));
        console2.log("Seeded default job exclusives");
        console2.log("Updated", ORACLE_DEPLOYMENT_PATH);
    }
}
