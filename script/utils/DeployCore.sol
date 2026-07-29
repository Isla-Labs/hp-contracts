// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";
import { AccessControl } from "@openzeppelin/access/AccessControl.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { AccessRoles as Roles } from "@roles/AccessRoles.sol";
import { VerifiedCallerConfig } from "@types/governance/AutomatorTypes.sol";

import { ConstitutionalTimelock } from "@governance/access/cat-1/ConstitutionalTimelock.sol";
import { MaintenanceTimelock } from "@governance/access/cat-2/MaintenanceTimelock.sol";
import { Automator } from "@governance/access/cat-3/Automator.sol";
import { DopplerLocker } from "@governance/deployments/assets/deploy/DopplerLocker.sol";
import { TransferLocker } from "@governance/deployments/assets/transfer/TransferLocker.sol";
import { DeployTournament } from "@governance/deployments/tournaments/DeployTournament.sol";

import { AddressProvider } from "@src/AddressProvider.sol";
import { TournamentRegistry } from "@src/TournamentRegistry.sol";
import { PlayerSetRegistry } from "@src/PlayerSetRegistry.sol";

import { ProxyUtils } from "./ProxyUtils.sol";

/**
 * @title DeployCore
 * @notice Bootstrap: AddressProvider, access stack, lockers, DeployTournament, registries.
 * @dev AddressBook upgradeables follow:
 *        1) Deploy AddressProvider
 *        2) Deploy proxies + AddressBook implementations (ctors only store the provider)
 *        3) Register names on AddressProvider
 *        4) Initialize proxies (resolve once into storage)
 *
 *      Non-AddressBook contracts (timelocks, lockers, Automator, DeployTournament) still take
 *      explicit ctor args. EligibilityVerifier proxy is created here so Automator can seed EV
 *      as a verified caller; DeployData upgrades that proxy.
 */
abstract contract DeployCore is ProxyUtils {
    struct CoreDeployment {
        address addressProvider;
        address initGuard;
        address constitutionalTimelock;
        address maintenanceTimelock;
        address transferLocker;
        address dopplerLocker;
        address eligibilityVerifier;
        address automator;
        address deployTournament;
        address tournamentRegistry;
        address playerSetRegistry;
        address tournamentRegistryImpl;
        address playerSetRegistryImpl;
    }

    function _deployCore(address dao, address deployer) internal returns (CoreDeployment memory d) {
        if (dao == address(0)) revert("DAO_ADDRESS required");
        if (deployer == address(0)) revert("deployer required");

        // --------------------------------------------
        //  1) AddressProvider (+ bootstrap access)
        // --------------------------------------------

        InitGuard guard = new InitGuard();
        d.initGuard = address(guard);

        d.constitutionalTimelock = address(new ConstitutionalTimelock(dao, 0));
        d.maintenanceTimelock = address(new MaintenanceTimelock(dao, 0));

        AddressProvider ap = new AddressProvider(deployer, d.constitutionalTimelock);
        d.addressProvider = address(ap);

        // --------------------------------------------
        //  2) Deploy upgradeables + sibling infrastructure
        // --------------------------------------------

        d.tournamentRegistry = _deployInitGuardProxy(guard, deployer);
        d.playerSetRegistry = _deployInitGuardProxy(guard, deployer);
        d.eligibilityVerifier = _deployInitGuardProxy(guard, deployer);

        d.tournamentRegistryImpl = address(new TournamentRegistry(d.addressProvider));
        d.playerSetRegistryImpl = address(new PlayerSetRegistry(d.addressProvider));

        d.dopplerLocker = address(new DopplerLocker(d.constitutionalTimelock, dao));
        d.transferLocker = address(new TransferLocker(d.playerSetRegistry, d.tournamentRegistry));

        address[] memory evDestinations = new address[](2);
        evDestinations[0] = d.dopplerLocker;
        evDestinations[1] = d.transferLocker;
        VerifiedCallerConfig[] memory callerConfigs = new VerifiedCallerConfig[](1);
        callerConfigs[0] = VerifiedCallerConfig({ caller: d.eligibilityVerifier, destinations: evDestinations });
        d.automator = address(new Automator(dao, d.constitutionalTimelock, callerConfigs));

        TransferLocker(d.transferLocker).setAutomator(d.automator);
        DopplerLocker(d.dopplerLocker).setAutomator(d.automator);

        d.deployTournament =
            address(new DeployTournament(d.constitutionalTimelock, dao, d.tournamentRegistry, d.playerSetRegistry));

        // --------------------------------------------
        //  3) Register AddressProvider names
        // --------------------------------------------

        ap.setName(Keys.DAO, dao);
        ap.setName(Keys.CONSTITUTIONAL_TIMELOCK, d.constitutionalTimelock);
        ap.setName(Keys.MAINTENANCE_TIMELOCK, d.maintenanceTimelock);
        ap.setName(Keys.AUTOMATOR, d.automator);
        ap.setName(Keys.CREATE_TOURNAMENT, d.deployTournament);
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

        if (deployer == dao) {
            AccessControl(d.tournamentRegistry).grantRole(Roles.CATEGORY_ONE, d.deployTournament);
            AccessControl(d.tournamentRegistry).grantRole(Roles.CATEGORY_THREE, d.deployTournament);
        } else {
            console.log("DAO != deployer: grant DeployTournament CAT_ONE + CAT_THREE on TournamentRegistry");
            AccessControl(d.addressProvider).grantRole(bytes32(0), dao);
        }

        _transferProxyAdmin(d.tournamentRegistry, d.constitutionalTimelock);
        _transferProxyAdmin(d.playerSetRegistry, d.constitutionalTimelock);
        // EV proxy admin stays with deployer until DeployData upgrades then transfers.

        _logCore(d);
    }

    function _logCore(CoreDeployment memory d) internal pure {
        console.log("AddressProvider", d.addressProvider);
        console.log("InitGuard", d.initGuard);
        console.log("ConstitutionalTimelock", d.constitutionalTimelock);
        console.log("MaintenanceTimelock", d.maintenanceTimelock);
        console.log("TransferLocker", d.transferLocker);
        console.log("DopplerLocker", d.dopplerLocker);
        console.log("EligibilityVerifier (proxy)", d.eligibilityVerifier);
        console.log("Automator", d.automator);
        console.log("DeployTournament", d.deployTournament);
        console.log("TournamentRegistry (proxy)", d.tournamentRegistry);
        console.log("PlayerSetRegistry (proxy)", d.playerSetRegistry);
    }
}
