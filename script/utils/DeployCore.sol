// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";

import { DopplerLocker } from "@deployments/assets/deploy/DopplerLocker.sol";
import { TransferLocker } from "@deployments/assets/transfer/TransferLocker.sol";
import { DeployTournament } from "@deployments/tournaments/DeployTournament.sol";
import { Orchestrator } from "@src/Orchestrator.sol";

import { AddressProvider } from "@src/AddressProvider.sol";
import { TournamentRegistry } from "@registries/TournamentRegistry.sol";
import { PlayerSetRegistry } from "@registries/PlayerSetRegistry.sol";

import { ProxyUtils } from "./ProxyUtils.sol";

/**
 * @title DeployCore
 * @notice Bootstrap: AddressProvider, Orchestrator, DeployTournament, lockers, registries.
 * @dev AddressBook upgradeables follow:
 *        1) Deploy AddressProvider (temporary owner = deployer)
 *        2) Deploy proxies + implementations
 *        3) Deploy Orchestrator + DeployTournament; authorize DT; register names
 *        4) Initialize proxies (resolve Orchestrator as owner)
 *        5) Transfer AddressProvider + ProxyAdmins to Orchestrator
 */
abstract contract DeployCore is ProxyUtils {
    struct CoreDeployment {
        address addressProvider;
        address initGuard;
        address transferLocker;
        address dopplerLocker;
        address orchestrator;
        address deployTournament;
        address tournamentRegistry;
        address playerSetRegistry;
        address tournamentRegistryImpl;
        address playerSetRegistryImpl;
    }

    function _deployCore(address owner, address deployer) internal returns (CoreDeployment memory d) {
        if (owner == address(0)) revert("OWNER_ADDRESS required");
        if (deployer == address(0)) revert("deployer required");

        // --------------------------------------------
        //  1) AddressProvider (+ temporary deployer ownership)
        // --------------------------------------------

        InitGuard guard = new InitGuard();
        d.initGuard = address(guard);

        AddressProvider ap = new AddressProvider(deployer);
        d.addressProvider = address(ap);

        // --------------------------------------------
        //  2) Deploy upgradeables + sibling infrastructure
        // --------------------------------------------

        d.tournamentRegistry = _deployInitGuardProxy(guard, deployer);
        d.playerSetRegistry = _deployInitGuardProxy(guard, deployer);

        d.tournamentRegistryImpl = address(new TournamentRegistry(d.addressProvider));
        d.playerSetRegistryImpl = address(new PlayerSetRegistry(d.addressProvider));

        d.orchestrator = address(new Orchestrator(owner));
        d.deployTournament =
            address(new DeployTournament(owner, d.orchestrator, d.tournamentRegistry, d.playerSetRegistry));

        if (deployer == owner) {
            Orchestrator(d.orchestrator).addAuthorizedContract(d.deployTournament);
        } else {
            console.log("OWNER != deployer: grant DeployTournament AUTHORIZED_CONTRACT on Orchestrator");
        }

        d.dopplerLocker = address(new DopplerLocker(d.orchestrator));
        d.transferLocker = address(new TransferLocker(d.orchestrator, d.playerSetRegistry, d.tournamentRegistry));

        // --------------------------------------------
        //  3) Register AddressProvider names
        // --------------------------------------------

        ap.setName(Keys.ORCHESTRATOR, d.orchestrator);
        ap.setName(Keys.DEPLOY_TOURNAMENT, d.deployTournament);
        ap.setName(Keys.TOURNAMENT_REGISTRY, d.tournamentRegistry);
        ap.setName(Keys.PLAYER_SET_REGISTRY, d.playerSetRegistry);
        ap.setName(Keys.DOPPLER_LOCKER, d.dopplerLocker);
        ap.setName(Keys.TRANSFER_LOCKER, d.transferLocker);

        // --------------------------------------------
        //  4) Initialize AddressBook upgradeables
        // --------------------------------------------

        _upgradeAndCall(
            d.tournamentRegistry, d.tournamentRegistryImpl, abi.encodeCall(TournamentRegistry.initialize, ())
        );
        _upgradeAndCall(d.playerSetRegistry, d.playerSetRegistryImpl, abi.encodeCall(PlayerSetRegistry.initialize, ()));

        // --------------------------------------------
        //  5) Hand ownership to Orchestrator
        // --------------------------------------------

        Ownable(d.addressProvider).transferOwnership(d.orchestrator);
        _transferProxyAdmin(d.tournamentRegistry, d.orchestrator);
        _transferProxyAdmin(d.playerSetRegistry, d.orchestrator);

        _logCore(d);
    }

    function _logCore(CoreDeployment memory d) internal pure {
        console.log("AddressProvider", d.addressProvider);
        console.log("InitGuard", d.initGuard);
        console.log("TransferLocker", d.transferLocker);
        console.log("DopplerLocker", d.dopplerLocker);
        console.log("Orchestrator", d.orchestrator);
        console.log("DeployTournament", d.deployTournament);
        console.log("TournamentRegistry (proxy)", d.tournamentRegistry);
        console.log("PlayerSetRegistry (proxy)", d.playerSetRegistry);
    }
}
