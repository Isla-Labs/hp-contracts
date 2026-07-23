// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Script } from "forge-std/Script.sol";
import { ProxyAdmin } from "@openzeppelin/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";

/**
 * @notice Helpers for TransparentUpgradeableProxy bootstrap (InitGuard → impl + init).
 * @dev OZ v5 deploys a dedicated `ProxyAdmin` per proxy. ERC-1967 admin slot holds that address.
 */
abstract contract ProxyUtils is Script {
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function _deployInitGuardProxy(InitGuard guard, address proxyAdminOwner) internal returns (address proxy) {
        proxy = address(new TransparentUpgradeableProxy(address(guard), proxyAdminOwner, ""));
    }

    function _proxyAdmin(address proxy) internal view returns (ProxyAdmin admin) {
        admin = ProxyAdmin(address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT)))));
    }

    function _upgradeAndCall(address proxy, address implementation, bytes memory data) internal {
        _proxyAdmin(proxy).upgradeAndCall(ITransparentUpgradeableProxy(proxy), implementation, data);
    }

    function _transferProxyAdmin(address proxy, address newOwner) internal {
        _proxyAdmin(proxy).transferOwnership(newOwner);
    }
}
