// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Script, console2 } from "forge-std/Script.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { CvmRouter } from "@src/oracle/CvmRouter.sol";
import { CvmRouterConfig } from "@types/oracle/CvmTypes.sol";

import { ProxyUtils } from "../utils/ProxyUtils.sol";

/**
 * @title DeployCvmRouter
 * @notice Deploy a new upgradeable CvmRouter proxy against an existing coordinator, or
 *         upgrade an existing router proxy (`ROUTER_PROXY` set).
 * @dev Env:
 *        PRIVATE_KEY, CVM_COORDINATOR
 *        DAO_ADDRESS / CONSTITUTIONAL_ADDRESS (new proxy only)
 *        ROUTER_PROXY — if set, upgrade that proxy to a new implementation (no re-init)
 */
contract DeployCvmRouter is Script, ProxyUtils {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address dao = vm.envOr("DAO_ADDRESS", deployer);
        address constitutional = vm.envOr("CONSTITUTIONAL_ADDRESS", deployer);
        address coordinator = vm.envAddress("CVM_COORDINATOR");

        vm.startBroadcast(privateKey);

        CvmRouter impl = new CvmRouter();

        if (vm.envExists("ROUTER_PROXY")) {
            address proxy = vm.envAddress("ROUTER_PROXY");
            _upgradeAndCall(proxy, address(impl), "");
            console2.log("Upgraded CvmRouter proxy", proxy);
            console2.log("New impl", address(impl));
        } else {
            InitGuard guard = new InitGuard();
            CvmRouterConfig memory routerConfig = CvmRouterConfig({
                maxCallbackGasLimit: 500_000,
                requestTimeout: uint32(1 days),
                gasForCallExactCheck: 5000,
                assigneeExclusiveSeconds: 5 minutes
            });
            address proxy = _deployInitGuardProxy(guard, dao);
            _upgradeAndCall(
                proxy,
                address(impl),
                abi.encodeCall(CvmRouter.initialize, (dao, constitutional, coordinator, routerConfig))
            );
            console2.log("CvmRouter proxy", proxy);
            console2.log("CvmRouter impl", address(impl));
        }

        vm.stopBroadcast();
        console2.log("CvmCoordinator", coordinator);
    }
}
