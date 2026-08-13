// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { PbrSettle } from "@src/data/performances/PbrSettle.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";

/**
 * @title DeployPbrSettle
 * @notice Immutable PbrSettle; register `PBR_SETTLE` on AddressProvider.
 * @dev `CVM_ROUTER` must already be on AddressProvider (ctor binds Oracle router).
 */
abstract contract DeployPbrSettle is AddressProviderOps {
    function _deployPbrSettle(address deployer) internal returns (address pbrSettle) {
        if (deployer == address(0)) revert("deployer required");

        address addressProvider = address(_requireAddressProvider());
        _requireName(Keys.CVM_ROUTER);
        _requireName(Keys.TOURNAMENT_REGISTRY);

        pbrSettle = address(new PbrSettle(addressProvider));
        _registerName(deployer, Keys.PBR_SETTLE, pbrSettle);

        console.log("=== DeployPbrSettle (immutable) ===");
        console.log("PbrSettle", pbrSettle);
    }
}
