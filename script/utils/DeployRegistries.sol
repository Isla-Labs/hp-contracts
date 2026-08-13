// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { TournamentRegistry } from "@registries/TournamentRegistry.sol";
import { PlayerSetRegistry } from "@registries/PlayerSetRegistry.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";

/**
 * @title DeployRegistries
 * @notice Immutable TournamentRegistry + PlayerSetRegistry; register both names on AP.
 * @dev Neither registry has `initialize` (AP role checks only).
 */
abstract contract DeployRegistries is AddressProviderOps {
    struct RegistryDeployment {
        address tournamentRegistry;
        address playerSetRegistry;
    }

    function _deployRegistries(address deployer) internal returns (RegistryDeployment memory d) {
        if (deployer == address(0)) revert("deployer required");
        address addressProvider = address(_requireAddressProvider());
        _requireName(Keys.ORCHESTRATOR);

        d.tournamentRegistry = address(new TournamentRegistry(addressProvider));
        d.playerSetRegistry = address(new PlayerSetRegistry(addressProvider));

        _registerName(deployer, Keys.TOURNAMENT_REGISTRY, d.tournamentRegistry);
        _registerName(deployer, Keys.PLAYER_SET_REGISTRY, d.playerSetRegistry);

        console.log("=== DeployRegistries (immutable) ===");
        console.log("TournamentRegistry", d.tournamentRegistry);
        console.log("PlayerSetRegistry", d.playerSetRegistry);
    }
}
