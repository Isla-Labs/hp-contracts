// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AccessRoles as Roles } from "@base/global/libraries/roles/AccessRoles.sol";
import { MatchweekErrors as Errors } from "@base/global/libraries/errors/data/MatchweekErrors.sol";
import { MatchweekEvents as Events } from "@base/global/libraries/events/data/MatchweekEvents.sol";
import { RoundSchedule } from "@base/global/types/TournamentTypes.sol";
import { IFixtureCommitment } from "@base/global/interfaces/data/IFixtureCommitment.sol";
import { IRoundManager } from "@base/global/interfaces/data/IRoundManager.sol";
import { ITournamentRegistry } from "@base/global/interfaces/ITournamentRegistry.sol";

/**
 * @title RoundManager
 * @notice Applies congruent schedule digests into `TournamentRegistry.RoundSchedule`.
 * @dev No zkVM. Flow:
 *        1) HP and CRE each `FixtureCommitment.commit` the same content-bound digest
 *        2) Anyone with `CATEGORY_THREE` calls `applyRound` / `applyRounds`
 *        3) This contract recomputes the digest from calldata, requires congruence,
 *           marks the commitment applied, then `TournamentRegistry.upsertRound(s)`
 *
 *      Deploy note: grant this contract `CATEGORY_THREE` on `TournamentRegistry` so
 *      `upsertRound` succeeds (`msg.sender` is RoundManager).
 *
 *      Weekly vault / `activeTournaments` sync is intentionally out of scope here
 *      (see `SquadCommitment` + a later activity path).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract RoundManager is Initializable, AccessControl, IRoundManager {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    ITournamentRegistry public immutable tournamentRegistry;
    IFixtureCommitment public immutable fixtureCommitment;

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address tournamentRegistry_, address fixtureCommitment_) {
        if (tournamentRegistry_ == address(0) || fixtureCommitment_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        tournamentRegistry = ITournamentRegistry(tournamentRegistry_);
        fixtureCommitment = IFixtureCommitment(fixtureCommitment_);
        _disableInitializers();
    }

    /**
     * @param automator_ `Automator` / CRE forwarder — `CATEGORY_THREE`.
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE`.
     */
    function initialize(address automator_, address dao_) external initializer {
        if (automator_ == address(0) || dao_ == address(0)) revert Errors.ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_THREE, automator_);
    }

    // --------------------------------------------
    //  Apply (after FixtureCommitment congruence)
    // --------------------------------------------

    /// @inheritdoc IRoundManager
    function applyRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        RoundSchedule calldata round,
        uint32 schemeEpoch
    ) external onlyRole(Roles.CATEGORY_THREE) {
        _applyRound(tournamentId, seasonStartYear, round, schemeEpoch);
    }

    /// @inheritdoc IRoundManager
    function applyRounds(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        RoundSchedule[] calldata rounds,
        uint32 schemeEpoch
    ) external onlyRole(Roles.CATEGORY_THREE) {
        uint256 length = rounds.length;
        for (uint256 i; i < length; ++i) {
            _applyRound(tournamentId, seasonStartYear, rounds[i], schemeEpoch);
        }
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _applyRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        RoundSchedule calldata round,
        uint32 schemeEpoch
    ) internal {
        if (tournamentId == bytes32(0)) revert Errors.ZeroId();
        if (seasonStartYear == 0 || round.roundNumber == 0) revert Errors.ZeroId();
        if (schemeEpoch == 0) revert Errors.InvalidSchemeEpoch();

        bytes32 key = fixtureCommitment.commitmentKey(tournamentId, seasonStartYear, round.roundNumber, schemeEpoch);
        if (!fixtureCommitment.isCongruent(key)) revert Errors.NotCongruent(key);

        bytes32 digest = fixtureCommitment.computeDigest(tournamentId, seasonStartYear, round, schemeEpoch);
        bytes32 committed = fixtureCommitment.getCommitment(key).hpDigest;
        if (digest != committed) revert Errors.DigestMismatch(key, committed, digest);

        fixtureCommitment.markApplied(key);
        tournamentRegistry.upsertRound(tournamentId, seasonStartYear, round);

        emit Events.ScheduleApplied(key, tournamentId, seasonStartYear, round.roundNumber, schemeEpoch);
    }
}
