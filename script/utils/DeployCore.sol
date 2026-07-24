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
 * @notice Bootstrap: AddressProvider, access stack, deployment lockers, DeployTournament, registries.
 * @dev Matchweeks / eligibility impl / PBR live in `DeployData`. Market/vault factories in
 *      `DeployFactories`.
 *
 *      EligibilityVerifier InitGuard proxy is created here so Automator can seed EV as a
 *      verified caller at construction. DeployData upgrades that proxy.
 *
 *      AddressProvider is seeded before AddressBook-aware ctors / `initialize` calls.
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

        InitGuard guard = new InitGuard();
        d.initGuard = address(guard);

        d.constitutionalTimelock = address(new ConstitutionalTimelock(dao, 0));
        d.maintenanceTimelock = address(new MaintenanceTimelock(dao, 0));

        // AddressProvider: deployer seeds bootstrap names, then hands DEFAULT_ADMIN to DAO if needed.
        AddressProvider ap = new AddressProvider(deployer, d.constitutionalTimelock);
        d.addressProvider = address(ap);

        ap.setName(Keys.DAO, dao);
        ap.setName(Keys.CONSTITUTIONAL_TIMELOCK, d.constitutionalTimelock);
        ap.setName(Keys.MAINTENANCE_TIMELOCK, d.maintenanceTimelock);

        d.dopplerLocker = address(new DopplerLocker(d.constitutionalTimelock, dao));
        ap.setName(Keys.DOPPLER_LOCKER, d.dopplerLocker);

        // Stable proxy addresses (impl = InitGuard until upgradeAndCall).
        d.tournamentRegistry = _deployInitGuardProxy(guard, deployer);
        d.playerSetRegistry = _deployInitGuardProxy(guard, deployer);
        // EV proxy early — Automator constructor seeds it as a verified caller.
        d.eligibilityVerifier = _deployInitGuardProxy(guard, deployer);

        ap.setName(Keys.TOURNAMENT_REGISTRY, d.tournamentRegistry);
        ap.setName(Keys.PLAYER_SET_REGISTRY, d.playerSetRegistry);

        // TransferLocker needs registry addresses for reactivate fee-topology checks.
        d.transferLocker = address(new TransferLocker(d.playerSetRegistry, d.tournamentRegistry));
        ap.setName(Keys.TRANSFER_LOCKER, d.transferLocker);

        address[] memory evDestinations = new address[](2);
        evDestinations[0] = d.dopplerLocker;
        evDestinations[1] = d.transferLocker;
        VerifiedCallerConfig[] memory callerConfigs = new VerifiedCallerConfig[](1);
        callerConfigs[0] =
            VerifiedCallerConfig({ caller: d.eligibilityVerifier, destinations: evDestinations });
        d.automator = address(new Automator(dao, d.constitutionalTimelock, callerConfigs));
        ap.setName(Keys.AUTOMATOR, d.automator);

        // Waiting rooms accept enqueue only from Automator (EV calls through Automator).
        TransferLocker(d.transferLocker).setAutomator(d.automator);
        DopplerLocker(d.dopplerLocker).setAutomator(d.automator);

        d.tournamentRegistryImpl = address(new TournamentRegistry(d.addressProvider));
        _upgradeAndCall(
            d.tournamentRegistry, d.tournamentRegistryImpl, abi.encodeCall(TournamentRegistry.initialize, ())
        );

        d.playerSetRegistryImpl = address(new PlayerSetRegistry(d.addressProvider));
        _upgradeAndCall(d.playerSetRegistry, d.playerSetRegistryImpl, abi.encodeCall(PlayerSetRegistry.initialize, ()));

        d.deployTournament =
            address(new DeployTournament(d.constitutionalTimelock, dao, d.tournamentRegistry, d.playerSetRegistry));
        ap.setName(Keys.CREATE_TOURNAMENT, d.deployTournament);

        if (deployer == dao) {
            AccessControl(d.tournamentRegistry).grantRole(Roles.CATEGORY_ONE, d.deployTournament);
            AccessControl(d.tournamentRegistry).grantRole(Roles.CATEGORY_THREE, d.deployTournament);
        } else {
            console.log("DAO != deployer: grant DeployTournament CAT_ONE + CAT_THREE on TournamentRegistry");
        }

        _transferProxyAdmin(d.tournamentRegistry, d.constitutionalTimelock);
        _transferProxyAdmin(d.playerSetRegistry, d.constitutionalTimelock);
        // EV proxy admin stays with deployer until DeployData upgrades then transfers.

        // Keep deployer as AddressProvider admin through later bootstrap scripts; also grant DAO.
        if (deployer != dao) {
            AccessControl(d.addressProvider).grantRole(bytes32(0), dao);
        }

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
