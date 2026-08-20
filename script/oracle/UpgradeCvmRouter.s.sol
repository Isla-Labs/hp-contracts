// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Script, console2 } from "forge-std/Script.sol";

import { AddressProvider } from "@src/AddressProvider.sol";
import { CvmRouter } from "@src/oracle/CvmRouter.sol";

import { AddressProviderOps } from "../utils/AddressProviderOps.sol";
import { CvmRequesterOps } from "../utils/CvmRequesterOps.sol";
import { OracleDeployment } from "../utils/OracleDeployment.sol";
import { ProxyUtils } from "../utils/ProxyUtils.sol";

/**
 * @title UpgradeCvmRouter
 * @notice Deploy a new CvmRouter implementation, upgrade the proxy from
 *         `deployments/base-sepolia-oracle.json`, seed per-job exclusives, and
 *         write `cvmRouterImpl` back to that file.
 * @dev Env: PRIVATE_KEY (must own ProxyAdmin; typically also Ownable owner for seed).
 *      Optional `ADDRESS_PROVIDER` reseeds the consumer allowlist (empty after this upgrade
 *      until `setRequester`). Optional `TEST_DATA` allowlists the Sepolia smoke consumer.
 *      Makefile: `make upgrade-base-sepolia-cvm-router`
 */
contract UpgradeCvmRouter is Script, ProxyUtils, OracleDeployment, AddressProviderOps, CvmRequesterOps {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        string memory json = _readOracleDeployment();
        address proxy = _oracleRouter(json);

        vm.startBroadcast(privateKey);
        CvmRouter impl = new CvmRouter();
        _upgradeAndCall(proxy, address(impl), "");
        // upgradeAndCall is admin-scoped; seed as the broadcaster (owner / deployer).
        CvmRouter(proxy).seedDefaultJobExclusives();
        address ap = _addressProviderOrZero();
        if (ap != address(0)) {
            _seedCvmRequesters(proxy, AddressProvider(payable(ap)));
        } else {
            console2.log("ADDRESS_PROVIDER unset - seed requesters via oracle-sepolia-set-requester");
        }
        if (vm.envExists("TEST_DATA")) {
            _allowCvmRequester(proxy, vm.envAddress("TEST_DATA"));
        }
        vm.stopBroadcast();

        _writeOracleImpl("cvmRouterImpl", address(impl));

        console2.log("Upgraded CvmRouter proxy", proxy);
        console2.log("New impl", address(impl));
        console2.log("Seeded default job exclusives");
        console2.log("Updated", ORACLE_DEPLOYMENT_PATH);
    }
}
