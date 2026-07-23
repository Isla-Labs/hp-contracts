// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { AccessControl } from "@openzeppelin/access/AccessControl.sol";

import { AccessRoles as Roles } from "@roles/AccessRoles.sol";
import { DeployTournament } from "@governance/deployments/tournaments/DeployTournament.sol";
import { FeeRouterFactory } from "@markets/factories/FeeRouterFactory.sol";
import { PbrFeeHubFactory } from "@markets/factories/PbrFeeHubFactory.sol";
import { PbrTreasuryFactory } from "@vaults/factories/PbrTreasuryFactory.sol";
import { PlayerVaultFactory } from "@vaults/factories/PlayerVaultFactory.sol";

/**
 * @title DeployFactories
 * @notice Market + vault beacon factories; wires `DeployTournament.configureFactories`.
 * @dev Requires Core addresses via env. `configureFactories` is cat-1 on DeployTournament —
 *      when `dao == deployer`, temporarily grant the deployer `CATEGORY_ONE` to call it.
 */
abstract contract DeployFactories is Script {
    struct FactoryDeployment {
        address feeRouterFactory;
        address pbrFeeHubFactory;
        address pbrTreasuryFactory;
        address playerVaultFactory;
    }

    struct CoreAddresses {
        address dao;
        address constitutionalTimelock;
        address maintenanceTimelock;
        address automator;
        address deployTournament;
        address tournamentRegistry;
        address playerSetRegistry;
    }

    function _loadCoreAddresses() internal view returns (CoreAddresses memory c) {
        c.dao = vm.envAddress("DAO_ADDRESS");
        c.constitutionalTimelock = vm.envAddress("CONSTITUTIONAL_TIMELOCK");
        c.maintenanceTimelock = vm.envAddress("MAINTENANCE_TIMELOCK");
        c.automator = vm.envAddress("AUTOMATOR");
        c.deployTournament = vm.envAddress("DEPLOY_TOURNAMENT");
        c.tournamentRegistry = vm.envAddress("TOURNAMENT_REGISTRY");
        c.playerSetRegistry = vm.envAddress("PLAYER_SET_REGISTRY");
    }

    function _deployFactories(address deployer) internal returns (FactoryDeployment memory f) {
        CoreAddresses memory c = _loadCoreAddresses();
        if (deployer == address(0)) revert("deployer required");

        f.feeRouterFactory = address(
            new FeeRouterFactory(
                c.automator, c.maintenanceTimelock, c.constitutionalTimelock, c.dao, c.tournamentRegistry
            )
        );

        f.playerVaultFactory = address(
            new PlayerVaultFactory(
                c.automator,
                c.maintenanceTimelock,
                c.dao,
                c.constitutionalTimelock,
                c.tournamentRegistry,
                c.playerSetRegistry
            )
        );

        f.pbrTreasuryFactory = address(
            new PbrTreasuryFactory(
                c.automator,
                c.maintenanceTimelock,
                c.constitutionalTimelock,
                c.dao,
                c.deployTournament,
                c.tournamentRegistry,
                c.playerSetRegistry
            )
        );

        f.pbrFeeHubFactory =
            address(new PbrFeeHubFactory(c.maintenanceTimelock, c.constitutionalTimelock, c.dao, c.deployTournament));

        if (deployer == c.dao) {
            // configureFactories is onlyRole(CATEGORY_ONE); constitutional delay blocks timelock path here.
            AccessControl(c.deployTournament).grantRole(Roles.CATEGORY_ONE, deployer);
            DeployTournament(c.deployTournament).configureFactories(f.pbrTreasuryFactory, f.pbrFeeHubFactory);
            AccessControl(c.deployTournament).revokeRole(Roles.CATEGORY_ONE, deployer);
        } else {
            console.log("DAO != deployer: schedule DeployTournament.configureFactories via ConstitutionalTimelock");
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
