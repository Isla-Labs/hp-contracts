// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";

import { DeployTournament } from "@deployments/tournaments/DeployTournament.sol";
import { FeeRouterFactory } from "@markets/factories/FeeRouterFactory.sol";
import { PbrFeeHubFactory } from "@markets/factories/PbrFeeHubFactory.sol";
import { PbrTreasuryFactory } from "@vaults/factories/PbrTreasuryFactory.sol";
import { PlayerVaultFactory } from "@vaults/factories/PlayerVaultFactory.sol";

/**
 * @title DeployFactories
 * @notice Market + vault beacon factories; wires `DeployTournament.configureFactories`.
 * @dev Non-upgradeable factories resolve AddressProvider slots in their constructors, so Core
 *      must already have registered `ORCHESTRATOR` + registry names.
 *      `configureFactories` is `onlyOwner` on DeployTournament — owner (EOA/Safe) must call it
 *      (or `OWNER_ADDRESS == deployer` for solo bootstrap).
 */
abstract contract DeployFactories is Script {
    struct FactoryDeployment {
        address feeRouterFactory;
        address pbrFeeHubFactory;
        address pbrTreasuryFactory;
        address playerVaultFactory;
    }

    struct CoreAddresses {
        address owner;
        address addressProvider;
        address deployTournament;
    }

    function _loadCoreAddresses() internal view returns (CoreAddresses memory c) {
        c.owner = vm.envOr("OWNER_ADDRESS", vm.envOr("DAO_ADDRESS", address(0)));
        c.addressProvider = vm.envAddress("ADDRESS_PROVIDER");
        c.deployTournament = vm.envOr("DEPLOY_TOURNAMENT", address(0));
    }

    function _deployFactories(address deployer) internal returns (FactoryDeployment memory f) {
        CoreAddresses memory c = _loadCoreAddresses();
        if (deployer == address(0)) revert("deployer required");
        if (c.addressProvider == address(0)) revert("ADDRESS_PROVIDER required");
        if (c.deployTournament == address(0)) revert("DEPLOY_TOURNAMENT required");

        f.feeRouterFactory = address(new FeeRouterFactory(c.addressProvider));
        f.playerVaultFactory = address(new PlayerVaultFactory(c.addressProvider));
        f.pbrTreasuryFactory = address(new PbrTreasuryFactory(c.addressProvider));
        f.pbrFeeHubFactory = address(new PbrFeeHubFactory(c.addressProvider));

        if (deployer == c.owner) {
            DeployTournament(c.deployTournament).configureFactories(f.pbrTreasuryFactory, f.pbrFeeHubFactory);
        } else {
            console.log("OWNER != deployer: call DeployTournament.configureFactories from the Safe/EOA owner");
        }

        _logFactories(f);
    }

    function _logFactories(FactoryDeployment memory f) internal pure {
        console.log("FeeRouterFactory", f.feeRouterFactory);
        console.log("PlayerVaultFactory", f.playerVaultFactory);
        console.log("PbrTreasuryFactory", f.pbrTreasuryFactory);
        console.log("PbrFeeHubFactory", f.pbrFeeHubFactory);
    }
}
