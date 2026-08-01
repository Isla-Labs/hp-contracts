// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Script, console2 } from "forge-std/Script.sol";

import { CvmRouter } from "@src/oracle/CvmRouter.sol";
import { CvmRouterConfig } from "@types/oracle/CvmTypes.sol";

/**
 * @title DeployCvmRouter
 * @notice Redeploy `CvmRouter` against an existing coordinator (e.g. after `CvmJob` enum growth).
 * @dev Env: PRIVATE_KEY, CVM_COORDINATOR, optional DAO_ADDRESS / CONSTITUTIONAL_ADDRESS
 *      Writes `deployments/base-sepolia-oracle.json` router field via Make merge, or logs address.
 */
contract DeployCvmRouter is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address dao = vm.envOr("DAO_ADDRESS", deployer);
        address constitutional = vm.envOr("CONSTITUTIONAL_ADDRESS", deployer);
        address coordinator = vm.envAddress("CVM_COORDINATOR");

        CvmRouterConfig memory routerConfig = CvmRouterConfig({
            maxCallbackGasLimit: 500_000, requestTimeout: uint32(1 days), gasForCallExactCheck: 5000
        });

        vm.startBroadcast(privateKey);
        CvmRouter router = new CvmRouter(dao, constitutional, coordinator, routerConfig);
        vm.stopBroadcast();

        console2.log("CvmRouter", address(router));
        console2.log("CvmCoordinator", coordinator);
    }
}
