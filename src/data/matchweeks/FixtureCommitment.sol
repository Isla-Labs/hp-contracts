// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AccessRoles as Roles } from "@base/global/libraries/roles/AccessRoles.sol";
import { MatchweekErrors as Errors } from "@base/global/libraries/errors/data/MatchweekErrors.sol";
import { MatchweekEvents as Events } from "@base/global/libraries/events/data/MatchweekEvents.sol";
import { RoundSchedule } from "@base/global/types/TournamentTypes.sol";
import { IFixtureCommitment } from "@base/global/interfaces/data/IFixtureCommitment.sol";
import { DigestSource, FixtureDigest } from "@src/data/matchweeks/types/MatchweekTypes.sol";

/**
 * @title FixtureCommitment
 * @notice Commit-then-attest digests for `RoundSchedule` payloads (CRE + HP, no zkVM).
 * @dev Content binding:
 *        `digest = keccak256(abi.encode(ROUND_SCHEDULE_KIND, tournamentId, seasonStartYear, round, schemeEpoch))`
 *
 *      Ordering: either source may write first. The second write must match or the tx reverts.
 *      Congruence (HP digest == CRE digest, both non-zero) is required before `RoundManager` apply.
 *
 *      Access:
 *      - `CATEGORY_THREE` (`Automator` / CRE forwarder): `commit`.
 *      - `RoundManager`: `markApplied`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract FixtureCommitment is Initializable, AccessControl, IFixtureCommitment {
    // --------------------------------------------
    //  Constants
    // --------------------------------------------

    /// @inheritdoc IFixtureCommitment
    bytes32 public constant ROUND_SCHEDULE_KIND = keccak256("ROUND_SCHEDULE");

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    address public roundManager;

    mapping(bytes32 key => FixtureDigest) private _commitments;

    // --------------------------------------------
    //  Access
    // --------------------------------------------

    modifier onlyRoundManager() {
        if (msg.sender != roundManager) revert Errors.NotAuthorized();
        _;
    }

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param automator_ `Automator` / CRE report forwarder — `CATEGORY_THREE`.
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE`.
     */
    function initialize(address automator_, address dao_) external initializer {
        if (automator_ == address(0) || dao_ == address(0)) revert Errors.ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_THREE, automator_);
    }

    /**
     * @notice One-time wire to `RoundManager` (apply path).
     * @dev Callable by DAO admin after `RoundManager` is deployed.
     */
    function setRoundManager(address roundManager_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (roundManager_ == address(0)) revert Errors.ZeroAddress();
        if (roundManager != address(0)) revert Errors.RoundManagerAlreadySet();
        roundManager = roundManager_;
        emit Events.RoundManagerSet(roundManager_);
    }

    // --------------------------------------------
    //  Digests
    // --------------------------------------------

    /// @inheritdoc IFixtureCommitment
    function commitmentKey(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        uint32 schemeEpoch
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(tournamentId, seasonStartYear, roundNumber, schemeEpoch));
    }

    /// @inheritdoc IFixtureCommitment
    function computeDigest(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        RoundSchedule calldata round,
        uint32 schemeEpoch
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(ROUND_SCHEDULE_KIND, tournamentId, seasonStartYear, round, schemeEpoch));
    }

    /**
     * @notice Posts an HP or CRE digest for a round schedule.
     * @dev Recomputes the content-bound digest from `round`. Second source must match the first.
     */
    function commit(
        DigestSource source,
        bytes32 tournamentId,
        uint16 seasonStartYear,
        RoundSchedule calldata round,
        uint32 schemeEpoch
    ) external onlyRole(Roles.CATEGORY_THREE) returns (bytes32 key, bytes32 digest) {
        if (tournamentId == bytes32(0)) revert Errors.ZeroId();
        if (seasonStartYear == 0 || round.roundNumber == 0) revert Errors.ZeroId();
        if (schemeEpoch == 0) revert Errors.InvalidSchemeEpoch();

        digest = computeDigest(tournamentId, seasonStartYear, round, schemeEpoch);
        if (digest == bytes32(0)) revert Errors.ZeroDigest();

        key = commitmentKey(tournamentId, seasonStartYear, round.roundNumber, schemeEpoch);
        FixtureDigest storage slot = _commitments[key];
        if (slot.applied) revert Errors.AlreadyApplied(key);

        if (source == DigestSource.HP) {
            if (slot.hpDigest != bytes32(0) && slot.hpDigest != digest) {
                revert Errors.DigestConflict(key, slot.hpDigest, digest);
            }
            if (slot.creDigest != bytes32(0) && slot.creDigest != digest) {
                revert Errors.DigestMismatch(key, slot.creDigest, digest);
            }
            slot.hpDigest = digest;
        } else {
            if (slot.creDigest != bytes32(0) && slot.creDigest != digest) {
                revert Errors.DigestConflict(key, slot.creDigest, digest);
            }
            if (slot.hpDigest != bytes32(0) && slot.hpDigest != digest) {
                revert Errors.DigestMismatch(key, slot.hpDigest, digest);
            }
            slot.creDigest = digest;
        }

        slot.schemeEpoch = schemeEpoch;

        emit Events.ScheduleDigestCommitted(
            key, source, tournamentId, seasonStartYear, round.roundNumber, schemeEpoch, digest
        );

        if (slot.hpDigest != bytes32(0) && slot.creDigest != bytes32(0) && slot.hpDigest == slot.creDigest) {
            emit Events.ScheduleCongruent(key, tournamentId, seasonStartYear, round.roundNumber, schemeEpoch, digest);
        }
    }

    /// @inheritdoc IFixtureCommitment
    function getCommitment(bytes32 key) external view returns (FixtureDigest memory) {
        return _commitments[key];
    }

    /// @inheritdoc IFixtureCommitment
    function isCongruent(bytes32 key) public view returns (bool) {
        FixtureDigest storage slot = _commitments[key];
        return
            slot.hpDigest != bytes32(0) && slot.creDigest != bytes32(0) && slot.hpDigest == slot.creDigest
                && !slot.applied;
    }

    /// @inheritdoc IFixtureCommitment
    function markApplied(bytes32 key) external onlyRoundManager {
        FixtureDigest storage slot = _commitments[key];
        if (!isCongruent(key)) revert Errors.NotCongruent(key);
        slot.applied = true;
    }
}
