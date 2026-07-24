// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";
import { AccessControl } from "@openzeppelin/access/AccessControl.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { AccessRoles as Roles } from "@roles/AccessRoles.sol";

import { DopplerLocker } from "@governance/deployments/assets/deploy/DopplerLocker.sol";

import { AddressProvider } from "@src/AddressProvider.sol";
import { EligibilityVerifier } from "@data/eligibility/EligibilityVerifier.sol";
import { FixtureCommitment } from "@data/matchweeks/FixtureCommitment.sol";
import { RoundManager } from "@data/matchweeks/RoundManager.sol";

import { ProxyUtils } from "./ProxyUtils.sol";

/**
 * @title DeployData
 * @notice CRE data plane: EligibilityVerifier, FixtureCommitment, RoundManager.
 * @dev PBR (`PpmVerifier` / `StatsCommitment`) are stubs — a reserved InitGuard address is
 *      registered as `PPM_VERIFIER` so EV can initialize; upgrade that slot when PBR ships.
 *
 *      Wiring:
 *        - Lockers already have `setAutomator` from DeployCore
 *        - EV proxy seeded as Automator verified caller in DeployCore
 *        - DopplerLocker `setEligibilityVerifier` (metadata oracle only)
 *        - RoundManager cat-3 on TournamentRegistry (direct); Automator caller add is cat-1 later if needed
 *        - FixtureCommitment.setRoundManager
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
        address addressProvider;
        address constitutionalTimelock;
        address automator;
        address transferLocker;
        address dopplerLocker;
        address eligibilityVerifier;
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
        c.addressProvider = vm.envAddress("ADDRESS_PROVIDER");
        c.constitutionalTimelock = vm.envAddress("CONSTITUTIONAL_TIMELOCK");
        c.automator = vm.envAddress("AUTOMATOR");
        c.transferLocker = vm.envAddress("TRANSFER_LOCKER");
        c.dopplerLocker = vm.envAddress("DOPPLER_LOCKER");
        c.eligibilityVerifier = vm.envAddress("ELIGIBILITY_VERIFIER");
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
        if (c.eligibilityVerifier == address(0)) revert("ELIGIBILITY_VERIFIER required");
        if (c.addressProvider == address(0)) revert("ADDRESS_PROVIDER required");

        InitGuard guard = InitGuard(payable(c.initGuard));
        AddressProvider ap = AddressProvider(c.addressProvider);

        d.eligibilityVerifier = c.eligibilityVerifier;
        d.fixtureCommitment = _deployInitGuardProxy(guard, deployer);
        d.roundManager = _deployInitGuardProxy(guard, deployer);
        // Sticky address for future PpmVerifier upgrade (stubs under data/pbr/ today).
        d.ppmVerifierPlaceholder = _deployInitGuardProxy(guard, deployer);

        ap.setName(Keys.CRE_FORWARDER, c.forwarder);
        ap.setName(Keys.PPM_VERIFIER, d.ppmVerifierPlaceholder);

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

        d.eligibilityVerifierImpl = address(new EligibilityVerifier(c.addressProvider, c.cooldown));
        _upgradeAndCall(
            d.eligibilityVerifier,
            d.eligibilityVerifierImpl,
            abi.encodeCall(EligibilityVerifier.initialize, (c.workflowId, c.leagueId, c.baseYear))
        );

        // Metadata oracle for DopplerLocker enqueue (writer is Automator).
        DopplerLocker(c.dopplerLocker).setEligibilityVerifier(d.eligibilityVerifier);

        if (deployer == c.dao) {
            FixtureCommitment(d.fixtureCommitment).setRoundManager(d.roundManager);
            AccessControl(c.tournamentRegistry).grantRole(Roles.CATEGORY_THREE, d.roundManager);
        } else {
            console.log("DAO != deployer: schedule setRoundManager + TR cat-3 for RoundManager");
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
