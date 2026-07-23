// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";
import { AccessControl } from "@openzeppelin/access/AccessControl.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { AccessRoles as Roles } from "@roles/AccessRoles.sol";

import { DopplerLocker } from "@governance/deployments/assets/deploy/DopplerLocker.sol";
import { TransferLocker } from "@governance/deployments/assets/transfer/TransferLocker.sol";

import { EligibilityVerifier } from "@data/eligibility/EligibilityVerifier.sol";
import { FixtureCommitment } from "@data/matchweeks/FixtureCommitment.sol";
import { RoundManager } from "@data/matchweeks/RoundManager.sol";

import { ProxyUtils } from "./ProxyUtils.sol";

/**
 * @title DeployData
 * @notice CRE data plane: EligibilityVerifier, FixtureCommitment, RoundManager.
 * @dev PBR (`PpmVerifier` / `StatsCommitment`) are stubs — a reserved InitGuard address is
 *      passed as `ppmVerifier` so EV can initialize; upgrade that slot when PBR ships.
 *
 *      Wiring:
 *        - EligibilityVerifier → DopplerLocker / TransferLocker (`setEligibilityVerifier`)
 *        - RoundManager + EV → Automator `CATEGORY_THREE` (DAO grant when dao == deployer)
 *        - FixtureCommitment.setRoundManager + RoundManager cat-3 on TournamentRegistry
 */
abstract contract DeployData is ProxyUtils {
    struct DataDeployment {
        address fixtureCommitment;
        address roundManager;
        address eligibilityVerifier;
        address ppmVerifierPlaceholder;
        address fixtureCommitmentImpl;
        address roundManagerImpl;
        address eligibilityVerifierImpl;
    }

    struct DataConfig {
        address dao;
        address deployer;
        address constitutionalTimelock;
        address automator;
        address transferLocker;
        address dopplerLocker;
        address tournamentRegistry;
        address playerSetRegistry;
        address initGuard;
        address forwarder;
        bytes32 workflowId;
        bytes32 leagueId;
        uint16 baseYear;
        uint256 cooldown;
    }

    function _loadDataConfig(address deployer) internal view returns (DataConfig memory c) {
        c.dao = vm.envAddress("DAO_ADDRESS");
        c.deployer = deployer;
        c.constitutionalTimelock = vm.envAddress("CONSTITUTIONAL_TIMELOCK");
        c.automator = vm.envAddress("AUTOMATOR");
        c.transferLocker = vm.envAddress("TRANSFER_LOCKER");
        c.dopplerLocker = vm.envAddress("DOPPLER_LOCKER");
        c.tournamentRegistry = vm.envAddress("TOURNAMENT_REGISTRY");
        c.playerSetRegistry = vm.envAddress("PLAYER_SET_REGISTRY");
        c.initGuard = vm.envAddress("INIT_GUARD");
        c.forwarder = vm.envAddress("KEYSTONE_FORWARDER");
        c.workflowId = vm.envBytes32("SQUAD_FILL_WORKFLOW_ID");
        c.leagueId = vm.envBytes32("LEAGUE_ID");
        c.baseYear = uint16(vm.envUint("BASE_YEAR"));
        c.cooldown = vm.envOr("ELIGIBILITY_COOLDOWN", uint256(1 hours));
    }

    function _deployData(address deployer) internal returns (DataDeployment memory d) {
        DataConfig memory c = _loadDataConfig(deployer);
        if (c.workflowId == bytes32(0)) revert("SQUAD_FILL_WORKFLOW_ID required");
        if (c.leagueId == bytes32(0)) revert("LEAGUE_ID required");
        if (c.baseYear == 0) revert("BASE_YEAR required");
        if (c.forwarder == address(0)) revert("KEYSTONE_FORWARDER required");

        InitGuard guard = InitGuard(payable(c.initGuard));

        d.fixtureCommitment = _deployInitGuardProxy(guard, deployer);
        d.roundManager = _deployInitGuardProxy(guard, deployer);
        d.eligibilityVerifier = _deployInitGuardProxy(guard, deployer);
        // Sticky address for future PpmVerifier upgrade (stubs under data/pbr/ today).
        d.ppmVerifierPlaceholder = _deployInitGuardProxy(guard, deployer);

        d.fixtureCommitmentImpl = address(new FixtureCommitment());
        _upgradeAndCall(
            d.fixtureCommitment,
            d.fixtureCommitmentImpl,
            abi.encodeCall(FixtureCommitment.initialize, (c.automator, c.dao))
        );

        d.roundManagerImpl = address(new RoundManager(c.tournamentRegistry, d.fixtureCommitment));
        _upgradeAndCall(
            d.roundManager, d.roundManagerImpl, abi.encodeCall(RoundManager.initialize, (c.automator, c.dao))
        );

        d.eligibilityVerifierImpl = address(new EligibilityVerifier(c.cooldown));
        _upgradeAndCall(
            d.eligibilityVerifier,
            d.eligibilityVerifierImpl,
            abi.encodeCall(
                EligibilityVerifier.initialize,
                (
                    c.constitutionalTimelock,
                    c.dao,
                    c.forwarder,
                    c.workflowId,
                    c.playerSetRegistry,
                    c.tournamentRegistry,
                    d.ppmVerifierPlaceholder,
                    c.dopplerLocker,
                    c.transferLocker,
                    c.leagueId,
                    c.baseYear
                )
            )
        );

        // Waiting-room writers (one-shot, no ACL — call immediately after EV create).
        DopplerLocker(c.dopplerLocker).setEligibilityVerifier(d.eligibilityVerifier);
        TransferLocker(c.transferLocker).setEligibilityVerifier(d.eligibilityVerifier);

        if (deployer == c.dao) {
            FixtureCommitment(d.fixtureCommitment).setRoundManager(d.roundManager);
            AccessControl(c.tournamentRegistry).grantRole(Roles.CATEGORY_THREE, d.roundManager);

            // Automator cat-3 allowlist (DEFAULT_ADMIN on Automator is DAO).
            AccessControl(c.automator).grantRole(Roles.CATEGORY_THREE, d.eligibilityVerifier);
            AccessControl(c.automator).grantRole(Roles.CATEGORY_THREE, d.roundManager);
            // Drop InitGuard placeholders seeded in DeployCore (`removeAutomator` is cat-1 only).
            AccessControl(c.automator).revokeRole(Roles.CATEGORY_THREE, c.initGuard);
        } else {
            console.log(
                "DAO != deployer: schedule setRoundManager, TR/Automator role grants, removeAutomator(InitGuard)"
            );
        }

        _transferProxyAdmin(d.fixtureCommitment, c.constitutionalTimelock);
        _transferProxyAdmin(d.roundManager, c.constitutionalTimelock);
        _transferProxyAdmin(d.eligibilityVerifier, c.constitutionalTimelock);
        _transferProxyAdmin(d.ppmVerifierPlaceholder, c.constitutionalTimelock);

        _logData(d);
    }

    function _logData(DataDeployment memory d) internal pure {
        console.log("FixtureCommitment (proxy)", d.fixtureCommitment);
        console.log("RoundManager (proxy)", d.roundManager);
        console.log("EligibilityVerifier (proxy)", d.eligibilityVerifier);
        console.log("PpmVerifier placeholder (proxy)", d.ppmVerifierPlaceholder);
    }
}
