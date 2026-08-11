// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { TournamentRegistry } from "@registries/TournamentRegistry.sol";
import { PlayerSetRegistry } from "@registries/PlayerSetRegistry.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";
import { ProxyUtils } from "./ProxyUtils.sol";

/**
 * @title DeployRegistries
 * @notice Step 4: TournamentRegistry + PlayerSetRegistry (TUP). Register both names, then upgrade.
 * @dev Neither registry has `initialize` (AP role checks). ProxyAdmin stays with deployer until
 *      DeployHandoff.
 */
abstract contract DeployRegistries is AddressProviderOps, ProxyUtils {
    struct RegistryDeployment {
        address tournamentRegistry;
        address tournamentRegistryImpl;
        address playerSetRegistry;
        address playerSetRegistryImpl;
        address initGuard;
    }

    function _deployRegistries(address deployer) internal returns (RegistryDeployment memory d) {
        if (deployer == address(0)) revert("deployer required");
        address addressProvider = address(_requireAddressProvider());
        _requireName(Keys.ORCHESTRATOR);

        InitGuard guard = new InitGuard();
        d.initGuard = address(guard);

        d.tournamentRegistry = _deployInitGuardProxy(guard, deployer);
        d.playerSetRegistry = _deployInitGuardProxy(guard, deployer);

        d.tournamentRegistryImpl = address(new TournamentRegistry(addressProvider));
        d.playerSetRegistryImpl = address(new PlayerSetRegistry(addressProvider));

        _registerName(deployer, Keys.TOURNAMENT_REGISTRY, d.tournamentRegistry);
        _registerName(deployer, Keys.PLAYER_SET_REGISTRY, d.playerSetRegistry);

        _upgradeAndCall(d.tournamentRegistry, d.tournamentRegistryImpl, "");
        _upgradeAndCall(d.playerSetRegistry, d.playerSetRegistryImpl, "");

        console.log("=== DeployRegistries ===");
        console.log("TournamentRegistry (proxy)", d.tournamentRegistry);
        console.log("TournamentRegistry (impl)", d.tournamentRegistryImpl);
        console.log("PlayerSetRegistry (proxy)", d.playerSetRegistry);
        console.log("PlayerSetRegistry (impl)", d.playerSetRegistryImpl);
    }
}
