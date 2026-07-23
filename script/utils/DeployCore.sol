// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";
import { AccessControl } from "@openzeppelin/access/AccessControl.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { AccessRoles as Roles } from "@base/global/libraries/roles/AccessRoles.sol";

import { ConstitutionalTimelock } from "@governance/access/cat-1/ConstitutionalTimelock.sol";
import { MaintenanceTimelock } from "@governance/access/cat-2/MaintenanceTimelock.sol";
import { Automator } from "@governance/access/cat-3/Automator.sol";
import { DopplerLocker } from "@governance/deployments/assets/deploy/DopplerLocker.sol";
import { TransferLocker } from "@governance/deployments/assets/transfer/TransferLocker.sol";

import { TournamentRegistry } from "@src/TournamentRegistry.sol";
import { PlayerSetRegistry } from "@src/PlayerSetRegistry.sol";
import { FixtureCommitment } from "@src/data/matchweeks/FixtureCommitment.sol";
import { RoundManager } from "@src/data/matchweeks/RoundManager.sol";

import { ProxyUtils } from "./ProxyUtils.sol";

/**
 * @title DeployCore
 * @notice Shared bootstrap for HighPotential core contracts (Base-first).
 * @dev Upgradeable singletons are deployed as TransparentUpgradeableProxies:
 *      1) Reserve addresses behind `InitGuard` (breaks circular address deps)
 *      2) Deploy real implementations that reference those proxy addresses
 *      3) `ProxyAdmin.upgradeAndCall` → `initialize(...)`
 *      4) Transfer each `ProxyAdmin` to `ConstitutionalTimelock`
 *
 *      Bootstrap note: `ConstitutionalTimelock` uses a 7d delay when `minDelay == 0`,
 *      so the deployer must own each `ProxyAdmin` during the InitGuard → impl step.
 *      Ownership is transferred to the timelock at the end of this script.
 *
 *      If `dao == msg.sender` (typical testnet), also wires `FixtureCommitment.setRoundManager`
 *      and grants `RoundManager` `CATEGORY_THREE` on `TournamentRegistry`. Otherwise those
 *      steps must be proposed through the DAO.
 */
abstract contract DeployCore is ProxyUtils {
    struct CoreDeployment {
        address initGuard;
        address constitutionalTimelock;
        address maintenanceTimelock;
        address transferLocker;
        address dopplerLocker;
        address automator;
        address tournamentRegistry;
        address playerSetRegistry;
        address fixtureCommitment;
        address roundManager;
        address tournamentRegistryImpl;
        address playerSetRegistryImpl;
        address fixtureCommitmentImpl;
        address roundManagerImpl;
    }

    function _deployCore(address dao, address deployer) internal returns (CoreDeployment memory d) {
        if (dao == address(0)) revert("DAO_ADDRESS required");
        if (deployer == address(0)) revert("deployer required");

        InitGuard guard = new InitGuard();
        d.initGuard = address(guard);

        ConstitutionalTimelock constitutional = new ConstitutionalTimelock(dao, 0);
        MaintenanceTimelock maintenance = new MaintenanceTimelock(dao, 0);
        d.constitutionalTimelock = address(constitutional);
        d.maintenanceTimelock = address(maintenance);

        TransferLocker transferLocker = new TransferLocker();
        DopplerLocker dopplerLocker = new DopplerLocker(d.constitutionalTimelock, dao);
        d.transferLocker = address(transferLocker);
        d.dopplerLocker = address(dopplerLocker);

        // Stable proxy addresses first (implementation = InitGuard; calls revert).
        d.tournamentRegistry = _deployInitGuardProxy(guard, deployer);
        d.playerSetRegistry = _deployInitGuardProxy(guard, deployer);
        d.fixtureCommitment = _deployInitGuardProxy(guard, deployer);
        d.roundManager = _deployInitGuardProxy(guard, deployer);

        // Automator needs non-zero cat-3 seeds. EligibilityVerifier is created later via factory;
        // InitGuard is a safe inert placeholder until `addAutomator(evProxy)`.
        Automator automator = new Automator(dao, d.constitutionalTimelock, d.dopplerLocker, d.initGuard, d.roundManager);
        d.automator = address(automator);

        // Implementations + initialize (proxy addresses are now stable for immutables).
        TournamentRegistry tournamentImpl = new TournamentRegistry();
        d.tournamentRegistryImpl = address(tournamentImpl);
        _upgradeAndCall(
            d.tournamentRegistry,
            d.tournamentRegistryImpl,
            abi.encodeCall(TournamentRegistry.initialize, (d.constitutionalTimelock, d.automator, dao))
        );

        PlayerSetRegistry playerSetImpl = new PlayerSetRegistry(d.tournamentRegistry);
        d.playerSetRegistryImpl = address(playerSetImpl);
        _upgradeAndCall(
            d.playerSetRegistry,
            d.playerSetRegistryImpl,
            abi.encodeCall(PlayerSetRegistry.initialize, (d.automator, dao))
        );

        FixtureCommitment fixtureImpl = new FixtureCommitment();
        d.fixtureCommitmentImpl = address(fixtureImpl);
        _upgradeAndCall(
            d.fixtureCommitment,
            d.fixtureCommitmentImpl,
            abi.encodeCall(FixtureCommitment.initialize, (d.automator, dao))
        );

        RoundManager roundManagerImpl = new RoundManager(d.tournamentRegistry, d.fixtureCommitment);
        d.roundManagerImpl = address(roundManagerImpl);
        _upgradeAndCall(d.roundManager, d.roundManagerImpl, abi.encodeCall(RoundManager.initialize, (d.automator, dao)));

        if (deployer == dao) {
            FixtureCommitment(d.fixtureCommitment).setRoundManager(d.roundManager);
            AccessControl(d.tournamentRegistry).grantRole(Roles.CATEGORY_THREE, d.roundManager);
        } else {
            console.log("DAO != deployer: schedule FixtureCommitment.setRoundManager + RoundManager CATEGORY_THREE");
        }

        // Upgrade authority → ConstitutionalTimelock (canonical owner).
        _transferProxyAdmin(d.tournamentRegistry, d.constitutionalTimelock);
        _transferProxyAdmin(d.playerSetRegistry, d.constitutionalTimelock);
        _transferProxyAdmin(d.fixtureCommitment, d.constitutionalTimelock);
        _transferProxyAdmin(d.roundManager, d.constitutionalTimelock);

        _logCore(d);
    }

    function _logCore(CoreDeployment memory d) internal pure {
        console.log("InitGuard", d.initGuard);
        console.log("ConstitutionalTimelock", d.constitutionalTimelock);
        console.log("MaintenanceTimelock", d.maintenanceTimelock);
        console.log("TransferLocker", d.transferLocker);
        console.log("DopplerLocker", d.dopplerLocker);
        console.log("Automator", d.automator);
        console.log("TournamentRegistry (proxy)", d.tournamentRegistry);
        console.log("PlayerSetRegistry (proxy)", d.playerSetRegistry);
        console.log("FixtureCommitment (proxy)", d.fixtureCommitment);
        console.log("RoundManager (proxy)", d.roundManager);
    }
}
