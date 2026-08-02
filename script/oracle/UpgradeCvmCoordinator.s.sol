// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Script, console2 } from "forge-std/Script.sol";

import { CvmCoordinator } from "@src/oracle/CvmCoordinator.sol";

import { ProxyUtils } from "../utils/ProxyUtils.sol";

/**
 * @title UpgradeCvmCoordinator
 * @notice Deploy a new CvmCoordinator implementation and upgrade `COORDINATOR_PROXY`.
 * @dev Env: PRIVATE_KEY, COORDINATOR_PROXY
 *      Caller must own the per-proxy ProxyAdmin (initially DAO/deployer).
 */
contract UpgradeCvmCoordinator is Script, ProxyUtils {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("COORDINATOR_PROXY");

        vm.startBroadcast(privateKey);
        CvmCoordinator impl = new CvmCoordinator();
        _upgradeAndCall(proxy, address(impl), "");
        vm.stopBroadcast();

        console2.log("Upgraded CvmCoordinator proxy", proxy);
        console2.log("New impl", address(impl));
    }
}
