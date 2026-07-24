// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";
import { AccessControl } from "@openzeppelin/access/AccessControl.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { AccessRoles as Roles } from "@roles/AccessRoles.sol";

import { ConstitutionalTimelock } from "@governance/access/cat-1/ConstitutionalTimelock.sol";
import { MaintenanceTimelock } from "@governance/access/cat-2/MaintenanceTimelock.sol";
import { Automator } from "@governance/access/cat-3/Automator.sol";
import { DopplerLocker } from "@governance/deployments/assets/deploy/DopplerLocker.sol";
import { TransferLocker } from "@governance/deployments/assets/transfer/TransferLocker.sol";
import { DeployTournament } from "@governance/deployments/tournaments/DeployTournament.sol";

import { TournamentRegistry } from "@src/TournamentRegistry.sol";
import { PlayerSetRegistry } from "@src/PlayerSetRegistry.sol";

import { ProxyUtils } from "./ProxyUtils.sol";

/**
 * @title DeployCore
 * @notice Bootstrap: access stack, deployment lockers, DeployTournament, registries.
 * @dev Matchweeks / eligibility / PBR live in `DeployData`. Market/vault factories in `DeployFactories`.
 *
 *      Automator seeds `DopplerLocker` as cat-3; EligibilityVerifier and RoundManager are
 *      `InitGuard` placeholders until `DeployData` grants the real addresses.
 */
abstract contract DeployCore is ProxyUtils {
    struct CoreDeployment {
        address initGuard;
        address constitutionalTimelock;
        address maintenanceTimelock;
        address transferLocker;
        address dopplerLocker;
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

        d.transferLocker = address(new TransferLocker());
        d.dopplerLocker = address(new DopplerLocker(d.constitutionalTimelock, dao));

        // Stable proxy addresses (impl = InitGuard until upgradeAndCall).
        d.tournamentRegistry = _deployInitGuardProxy(guard, deployer);
        d.playerSetRegistry = _deployInitGuardProxy(guard, deployer);

        // EV + matchweeks placeholders — replaced in DeployData via DAO grantRole / addAutomator.
        d.automator = address(new Automator(dao, d.constitutionalTimelock, d.dopplerLocker, d.initGuard, d.initGuard));

        // Waiting rooms accept enqueue only from Automator (EV relays via routes).
        TransferLocker(d.transferLocker).setAutomator(d.automator);
        DopplerLocker(d.dopplerLocker).setAutomator(d.automator);

        d.tournamentRegistryImpl = address(new TournamentRegistry());
        _upgradeAndCall(
            d.tournamentRegistry,
            d.tournamentRegistryImpl,
            abi.encodeCall(TournamentRegistry.initialize, (d.constitutionalTimelock, d.automator, dao))
        );

        d.playerSetRegistryImpl = address(new PlayerSetRegistry(d.tournamentRegistry));
        _upgradeAndCall(
            d.playerSetRegistry,
            d.playerSetRegistryImpl,
            abi.encodeCall(PlayerSetRegistry.initialize, (d.automator, dao))
        );

        d.deployTournament =
            address(new DeployTournament(d.constitutionalTimelock, dao, d.tournamentRegistry, d.playerSetRegistry));

        if (deployer == dao) {
            AccessControl(d.tournamentRegistry).grantRole(Roles.CATEGORY_ONE, d.deployTournament);
            AccessControl(d.tournamentRegistry).grantRole(Roles.CATEGORY_THREE, d.deployTournament);
        } else {
            console.log("DAO != deployer: grant DeployTournament CAT_ONE + CAT_THREE on TournamentRegistry");
        }

        _transferProxyAdmin(d.tournamentRegistry, d.constitutionalTimelock);
        _transferProxyAdmin(d.playerSetRegistry, d.constitutionalTimelock);

        _logCore(d);
    }

    function _logCore(CoreDeployment memory d) internal pure {
        console.log("InitGuard", d.initGuard);
        console.log("ConstitutionalTimelock", d.constitutionalTimelock);
        console.log("MaintenanceTimelock", d.maintenanceTimelock);
        console.log("TransferLocker", d.transferLocker);
        console.log("DopplerLocker", d.dopplerLocker);
        console.log("Automator", d.automator);
        console.log("DeployTournament", d.deployTournament);
        console.log("TournamentRegistry (proxy)", d.tournamentRegistry);
        console.log("PlayerSetRegistry (proxy)", d.playerSetRegistry);
    }
}
