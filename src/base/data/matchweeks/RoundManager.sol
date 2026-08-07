// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { MatchweekErrors as Errors } from "@errors/data/MatchweekErrors.sol";
import { MatchweekEvents as Events } from "@events/data/MatchweekEvents.sol";
import { RoundSchedule } from "@types/TournamentTypes.sol";
import { IRoundManager } from "@interfaces/data/IRoundManager.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";

/**
 * @title RoundManager
 * @notice Round-calendar SoT (`finalRound` + `RoundSchedule`) for registry-opened seasons.
 * @dev Season identity stays on `TournamentRegistry`; this contract owns calendar writes/views.
 *      Oracle fetch helpers (`fetchRoundsLatest` / historical) land later.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract RoundManager is Initializable, AddressBook, Ownable, IRoundManager {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    ITournamentRegistry public tournamentRegistry;

    mapping(bytes32 tournamentId => mapping(uint16 seasonStartYear => uint32 finalRound)) private _finalRounds;

    mapping(
        bytes32 tournamentId
            => mapping(uint16 seasonStartYear => mapping(uint32 roundNumber => RoundSchedule schedule))
    ) private _rounds;

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    /// @notice Transfers ownership to `Orchestrator` and caches `TournamentRegistry`.
    function initialize() external initializer {
        _transferOwnership(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));
        tournamentRegistry = ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }

    // --------------------------------------------
    //  Writes — owner (Orchestrator)
    // --------------------------------------------

    /// @inheritdoc IRoundManager
    function setFinalRound(bytes32 tournamentId, uint16 seasonStartYear, uint32 finalRound) external onlyOwner {
        if (tournamentId == bytes32(0) || seasonStartYear == 0) revert Errors.ZeroId();
        if (finalRound == 0) revert Errors.InvalidFinalRound();

        bytes32 seasonId = tournamentRegistry.getSeasonId(tournamentId, seasonStartYear);
        if (seasonId == bytes32(0)) revert Errors.SeasonNotOpen(tournamentId, seasonStartYear);

        _finalRounds[tournamentId][seasonStartYear] = finalRound;
        emit Events.FinalRoundSet(tournamentId, seasonId, seasonStartYear, finalRound);
    }

    /// @inheritdoc IRoundManager
    function upsertRound(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule calldata round)
        external
        onlyOwner
    {
        _upsertRound(tournamentId, seasonStartYear, round);
    }

    /// @inheritdoc IRoundManager
    function upsertRounds(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule[] calldata rounds)
        external
        onlyOwner
    {
        uint256 length = rounds.length;
        for (uint256 i; i < length; ++i) {
            _upsertRound(tournamentId, seasonStartYear, rounds[i]);
        }
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc IRoundManager
    function getFinalRound(bytes32 tournamentId, uint16 seasonStartYear) external view returns (uint32) {
        return _finalRounds[tournamentId][seasonStartYear];
    }

    /// @inheritdoc IRoundManager
    function getRound(bytes32 tournamentId, uint16 seasonStartYear, uint32 roundNumber)
        external
        view
        returns (RoundSchedule memory)
    {
        RoundSchedule storage schedule = _rounds[tournamentId][seasonStartYear][roundNumber];
        if (schedule.roundNumber == 0) {
            revert Errors.RoundNotFound(tournamentId, seasonStartYear, roundNumber);
        }
        return schedule;
    }

    /// @inheritdoc IRoundManager
    function isRoundPublished(bytes32 tournamentId, uint16 seasonStartYear, uint32 roundNumber)
        external
        view
        returns (bool)
    {
        RoundSchedule storage schedule = _rounds[tournamentId][seasonStartYear][roundNumber];
        return schedule.roundNumber != 0 && schedule.startTime != 0 && schedule.endTime > schedule.startTime
            && schedule.fixtureIds.length != 0;
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _upsertRound(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule calldata round) internal {
        if (tournamentId == bytes32(0) || seasonStartYear == 0) revert Errors.ZeroId();
        if (round.roundNumber == 0) revert Errors.ZeroId();
        if (round.startTime == 0 || round.endTime <= round.startTime) {
            revert Errors.InvalidTimeRange(round.startTime, round.endTime);
        }

        uint32 finalRound = _finalRounds[tournamentId][seasonStartYear];
        if (finalRound == 0) revert Errors.SeasonNotOpen(tournamentId, seasonStartYear);
        if (round.roundNumber > finalRound) {
            revert Errors.InvalidRoundNumber(round.roundNumber, finalRound);
        }

        // Confirm season identity exists on the registry.
        if (tournamentRegistry.getSeasonId(tournamentId, seasonStartYear) == bytes32(0)) {
            revert Errors.SeasonNotOpen(tournamentId, seasonStartYear);
        }

        RoundSchedule storage stored = _rounds[tournamentId][seasonStartYear][round.roundNumber];
        stored.roundNumber = round.roundNumber;
        stored.startTime = round.startTime;
        stored.endTime = round.endTime;
        stored.fixtureIds = round.fixtureIds;

        emit Events.RoundUpserted(tournamentId, seasonStartYear, round.roundNumber);
    }
}
