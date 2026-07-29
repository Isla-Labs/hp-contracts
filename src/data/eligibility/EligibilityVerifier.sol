// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { IReceiver } from "@cre/v1/interfaces/IReceiver.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { CreReceiver } from "@base/abstract/CreReceiver.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { AccessRoles as Roles } from "@roles/AccessRoles.sol";
import { EligibilityErrors as Errors } from "@errors/data/EligibilityErrors.sol";

import { EligibilityCriteria } from "./base/EligibilityCriteria.sol";
import { EligibilityStore } from "./EligibilityStore.sol";

/**
 * @title EligibilityVerifier
 * @notice Top layer: AddressBook wiring, ops roles, criteria, and (later) verify scan.
 * @dev Proxy-initialized. Separation:
 *        - `EligibilityStore` — CRE squads + `recordAppearances` / score math
 *        - `EligibilityCriteria` — governance thresholds only
 *        - this contract — AddressProvider resolution, role-gated ops, scan/handoff
 *
 *      Squads CRE reports → `onReport` → store `_processReport`.
 *      PpmVerifier → store `recordAppearances`.
 *      Steady-state league sync is CRE `SYNC_LEAGUE` (Automator may `queueLeague`).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract EligibilityVerifier is Initializable, AddressBook, EligibilityStore, EligibilityCriteria {
    /// @notice Verify-scan cooldown (seconds); used by later eligibility scan paths.
    uint256 public cooldown;

    /// @param addressProvider_ Canonical `AddressProvider`.
    /// @param cooldown_ Min seconds between verify scans (governance may retune later).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_, uint256 cooldown_) AddressBook(addressProvider_) {
        if (cooldown_ == 0) revert Errors.InvalidThreshold();
        cooldown = cooldown_;
        _disableInitializers();
    }

    /**
     * @notice Proxy init: roles, criteria defaults, CRE forwarder + workflow id, year clocks.
     * @param workflowId_ Expected CRE workflow id (squads `eligibility-store`).
     * @param leagueId_ Reserved (multi-league RunBook; ignored — kept for DeployData ABI).
     * @param baseYear_ Sets `scoreBaseYear` (G-index origin) and initial `currentSeasonStartYear`.
     */
    function initialize(bytes32 workflowId_, bytes32 leagueId_, uint16 baseYear_) external initializer {
        leagueId_; // silence — RunBook is multi-league; sync via CRE / queueLeague
        if (workflowId_ == bytes32(0)) revert Errors.ZeroWorkflowId();
        if (baseYear_ == 0) revert Errors.ZeroId();

        address dao_ = _getAddress(_addressKey(Addresses.DAO));
        address constitutionalTimelock_ = _getAddress(_addressKey(Addresses.CONSTITUTIONAL_TIMELOCK));
        address automator_ = _getAddress(_addressKey(Addresses.AUTOMATOR));
        address forwarder_ = _getAddress(_addressKey(Addresses.CRE_FORWARDER));

        __EligibilityCriteria_init(constitutionalTimelock_, dao_);
        _grantRole(Roles.CATEGORY_THREE, automator_);

        __CreReceiver_init(forwarder_);
        _setExpectedWorkflowId(workflowId_);
        _setScoreBaseYear(baseYear_);
        _setCurrentSeasonStartYear(baseYear_);
    }

    // --------------------------------------------
    //  Ops — CATEGORY_THREE (Automator) / CATEGORY_ONE
    // --------------------------------------------

    /// @notice Manually queue a league's seasons (oldest→newest). Prefer CRE `SYNC_LEAGUE`.
    function queueLeague(
        bytes32 leagueId,
        bytes32[] calldata seasonIds,
        uint16[] calldata seasonStartYears
    ) external onlyRole(Roles.CATEGORY_THREE) {
        _queueLeague(leagueId, seasonIds, seasonStartYears);
    }

    /// @notice Set / retune `currentSeasonStartYear` while idle (monotonic tick usually via finalize).
    function setCurrentSeasonStartYear(uint16 year) external onlyRole(Roles.CATEGORY_ONE) {
        _setCurrentSeasonStartYear(year);
    }

    function setExpectedWorkflowId(bytes32 workflowId_) external onlyRole(Roles.CATEGORY_ONE) {
        if (workflowId_ == bytes32(0)) revert Errors.ZeroWorkflowId();
        _setExpectedWorkflowId(workflowId_);
    }

    function setForwarderAddress(address forwarder_) external onlyRole(Roles.CATEGORY_ONE) {
        _setForwarderAddress(forwarder_);
    }

    // --------------------------------------------
    //  AddressBook → store hooks
    // --------------------------------------------

    function _ppmVerifier() internal view override returns (address) {
        return _getAddress(_addressKey(Addresses.PPM_VERIFIER));
    }

    function _tournamentRegistry() internal view override returns (ITournamentRegistry) {
        return ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControl, CreReceiver) returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || AccessControl.supportsInterface(interfaceId)
            || CreReceiver.supportsInterface(interfaceId);
    }
}
