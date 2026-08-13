// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { FeeRouterFactory } from "@markets/factories/FeeRouterFactory.sol";
import { PbrFeeHubFactory } from "@markets/factories/PbrFeeHubFactory.sol";
import { PbrTreasuryFactory } from "@vaults/factories/PbrTreasuryFactory.sol";
import { PlayerVaultFactory } from "@vaults/factories/PlayerVaultFactory.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";

/**
 * @title DeployFactories
 * @notice Market + vault factories; register on AP.
 * @dev All four factories are immutable (`new` after ORCHESTRATOR + TIMELOCK are on AP).
 *      Shared beacons are owned by TIMELOCK (ConstitutionalTimelock).
 */
abstract contract DeployFactories is AddressProviderOps {
    struct FactoryDeployment {
        address feeRouterFactory;
        address pbrFeeHubFactory;
        address pbrTreasuryFactory;
        address playerVaultFactory;
    }

    function _deployFactories(address deployer) internal returns (FactoryDeployment memory f) {
        if (deployer == address(0)) revert("deployer required");

        address addressProvider = address(_requireAddressProvider());
        _requireName(Keys.ORCHESTRATOR);
        _requireName(Keys.TIMELOCK);

        f.feeRouterFactory = address(new FeeRouterFactory(addressProvider));
        f.pbrFeeHubFactory = address(new PbrFeeHubFactory(addressProvider));
        f.playerVaultFactory = address(new PlayerVaultFactory(addressProvider));
        f.pbrTreasuryFactory = address(new PbrTreasuryFactory(addressProvider));

        _registerName(deployer, Keys.FEE_ROUTER_FACTORY, f.feeRouterFactory);
        _registerName(deployer, Keys.PLAYER_VAULT_FACTORY, f.playerVaultFactory);
        _registerName(deployer, Keys.PBR_TREASURY_FACTORY, f.pbrTreasuryFactory);
        _registerName(deployer, Keys.PBR_FEE_HUB_FACTORY, f.pbrFeeHubFactory);

        console.log("=== DeployFactories (immutable) ===");
        console.log("FeeRouterFactory", f.feeRouterFactory);
        console.log("PbrFeeHubFactory", f.pbrFeeHubFactory);
        console.log("PlayerVaultFactory", f.playerVaultFactory);
        console.log("PbrTreasuryFactory", f.pbrTreasuryFactory);
    }
}
