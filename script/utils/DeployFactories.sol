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
 * @dev Non-upgradeable factories resolve AddressProvider slots in their constructors, so Core
 *      must already have registered governance + registry names. Beacon child proxies still
 *      resolve roles at their own `initialize` (after factory deploy).
 *      `configureFactories` is cat-1 on DeployTournament — when `dao == deployer`, temporarily
 *      grant the deployer `CATEGORY_ONE` to call it.
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
        address addressProvider;
        address deployTournament;
    }

    function _loadCoreAddresses() internal view returns (CoreAddresses memory c) {
        c.dao = vm.envAddress("DAO_ADDRESS");
        c.addressProvider = vm.envAddress("ADDRESS_PROVIDER");
        c.deployTournament = vm.envAddress("DEPLOY_TOURNAMENT");
    }

    function _deployFactories(address deployer) internal returns (FactoryDeployment memory f) {
        CoreAddresses memory c = _loadCoreAddresses();
        if (deployer == address(0)) revert("deployer required");
        if (c.addressProvider == address(0)) revert("ADDRESS_PROVIDER required");

        f.feeRouterFactory = address(new FeeRouterFactory(c.addressProvider));
        f.playerVaultFactory = address(new PlayerVaultFactory(c.addressProvider));
        f.pbrTreasuryFactory = address(new PbrTreasuryFactory(c.addressProvider));
        f.pbrFeeHubFactory = address(new PbrFeeHubFactory(c.addressProvider));

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
