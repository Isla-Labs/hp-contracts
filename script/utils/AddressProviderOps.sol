// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";

import { AddressProvider } from "@src/AddressProvider.sol";

/**
 * @title AddressProviderOps
 * @notice Shared helpers for sequential deploy scripts that register names while
 *         deployer still holds AddressProvider `DEFAULT_ADMIN_ROLE` (pre–timelock handoff).
 */
abstract contract AddressProviderOps is Script {
    function _addressProviderOrZero() internal view returns (address) {
        if (!vm.envExists("ADDRESS_PROVIDER")) return address(0);
        return vm.envAddress("ADDRESS_PROVIDER");
    }

    function _requireAddressProvider() internal view returns (AddressProvider ap) {
        address addr = _addressProviderOrZero();
        if (addr == address(0)) revert("ADDRESS_PROVIDER required");
        ap = AddressProvider(payable(addr));
    }

    /// @notice `setName` — reverts unless AP is set and deployer has `DEFAULT_ADMIN_ROLE`.
    function _registerName(address deployer, string memory name, address addr) internal {
        AddressProvider ap = _requireAddressProvider();
        if (!ap.hasRole(ap.DEFAULT_ADMIN_ROLE(), deployer)) {
            revert("AddressProvider DEFAULT_ADMIN must be deployer until ConstitutionalTimelock handoff");
        }
        if (addr == address(0)) revert("cannot register zero address");
        ap.setName(name, addr);
        console.log(name, addr);
    }

    /// @notice Soft register for optional steps (e.g. oracle before AP exists).
    function _tryRegisterName(address deployer, string memory name, address addr) internal {
        address apAddr = _addressProviderOrZero();
        if (apAddr == address(0)) {
            console.log("ADDRESS_PROVIDER unset - skip setName for", name);
            return;
        }
        AddressProvider ap = AddressProvider(payable(apAddr));
        if (!ap.hasRole(ap.DEFAULT_ADMIN_ROLE(), deployer)) {
            console.log("AddressProvider DEFAULT_ADMIN != deployer - skip setName for", name);
            return;
        }
        if (addr == address(0)) {
            console.log("zero address - skip setName for", name);
            return;
        }
        ap.setName(name, addr);
        console.log(name, addr);
    }

    function _requireName(string memory name) internal view returns (address addr) {
        AddressProvider ap = _requireAddressProvider();
        addr = ap.getByName(name);
        if (addr == address(0)) {
            revert(string.concat(name, " missing on AddressProvider"));
        }
    }

    function _ownerOrDeployer(address deployer) internal view returns (address) {
        return vm.envOr("OWNER_ADDRESS", vm.envOr("DAO_ADDRESS", deployer));
    }
}
