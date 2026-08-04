// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { DeployTournament } from "@deployments/tournaments/DeployTournament.sol";
import { FeeRouterFactory } from "@markets/factories/FeeRouterFactory.sol";
import { PbrFeeHubFactory } from "@markets/factories/PbrFeeHubFactory.sol";
import { PbrTreasuryFactory } from "@vaults/factories/PbrTreasuryFactory.sol";
import { PlayerVaultFactory } from "@vaults/factories/PlayerVaultFactory.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";

/**
 * @title DeployFactories
 * @notice Step 8: market + vault beacon factories; configure DeployTournament; register on AP.
 * @dev Direct `ap.setName` while deployer still owns AddressProvider (pre-handoff).
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
        address deployTournament = _requireName(Keys.DEPLOY_TOURNAMENT);
        _requireName(Keys.ORCHESTRATOR);

        address owner = _ownerOrDeployer(deployer);

        f.feeRouterFactory = address(new FeeRouterFactory(addressProvider));
        f.playerVaultFactory = address(new PlayerVaultFactory(addressProvider));
        f.pbrTreasuryFactory = address(new PbrTreasuryFactory(addressProvider));
        f.pbrFeeHubFactory = address(new PbrFeeHubFactory(addressProvider));

        if (deployer == owner) {
            DeployTournament(deployTournament).configureFactories(f.pbrTreasuryFactory, f.pbrFeeHubFactory);
            _registerName(deployer, Keys.FEE_ROUTER_FACTORY, f.feeRouterFactory);
            _registerName(deployer, Keys.PLAYER_VAULT_FACTORY, f.playerVaultFactory);
            _registerName(deployer, Keys.PBR_TREASURY_FACTORY, f.pbrTreasuryFactory);
            _registerName(deployer, Keys.PBR_FEE_HUB_FACTORY, f.pbrFeeHubFactory);
        } else {
            console.log("OWNER != deployer: from the Safe/EOA owner call:");
            console.log("  1) DeployTournament.configureFactories(treasuryFactory, feeHubFactory)");
            console.log("  2) AddressProvider.setName for each factory (or Orchestrator.execute after handoff)");
        }

        console.log("=== DeployFactories ===");
        console.log("FeeRouterFactory", f.feeRouterFactory);
        console.log("PlayerVaultFactory", f.playerVaultFactory);
        console.log("PbrTreasuryFactory", f.pbrTreasuryFactory);
        console.log("PbrFeeHubFactory", f.pbrFeeHubFactory);
    }
}
