// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Tournament, Season, Matchweek, Cup, Round } from "@base/global/types/TournamentTypes.sol";

/**
 * @title TournamentRegistry
 * @notice Canonical onchain registry of supported tournaments for data collection and calendar windows.
 * @dev Nested dynamic arrays cannot be assigned wholesale from memory to storage; mutators write
 *      fields / push elements individually. Existence is keyed by `pbrTreasury != address(0)`.
 *      Use the typed view helpers for seasons, matchweeks, cups, and rounds.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TournamentRegistry is Ownable {
    /// @notice leagueId => tournament metadata and calendar hierarchy
    mapping(bytes32 => Tournament) private _tournaments;

    // --------------------------------------------
    //  Events
    // --------------------------------------------

    /// @notice Emitted when a league is registered with its PBR treasury
    event TournamentCreated(bytes32 indexed leagueId, address indexed pbrTreasury);

    /// @notice Emitted when a season is appended to a tournament
    event SeasonAdded(bytes32 indexed leagueId, uint32 indexed startYear, uint256 seasonIndex);

    /// @notice Emitted when a matchweek is appended to a season
    event MatchweekAdded(bytes32 indexed leagueId, uint256 indexed seasonIndex, uint32 mwNumber, uint256 mwIndex);

    /// @notice Emitted when matchweek window timestamps are updated in isolation
    event MatchweekTimesUpdated(
        bytes32 indexed leagueId,
        uint256 indexed seasonIndex,
        uint256 indexed mwIndex,
        uint64 mwStartTime,
        uint64 mwEndTime
    );

    /// @notice Emitted when a domestic cup is appended to a season
    event CupAdded(bytes32 indexed leagueId, uint256 indexed seasonIndex, bytes32 indexed cupId, uint256 cupIndex);

    /// @notice Emitted when a round is appended to a cup
    event RoundAdded(
        bytes32 indexed leagueId, uint256 indexed seasonIndex, uint256 indexed cupIndex, uint32 roundNumber, uint256 roundIndex
    );

    /// @notice Emitted when round window timestamps are updated in isolation
    event RoundTimesUpdated(
        bytes32 indexed leagueId,
        uint256 indexed seasonIndex,
        uint256 cupIndex,
        uint256 roundIndex,
        uint64 roundStartTime,
        uint64 roundEndTime
    );

    // --------------------------------------------
    //  Errors
    // --------------------------------------------

    error ZeroAddress();
    error ZeroId();
    error TournamentAlreadyExists(bytes32 leagueId);
    error TournamentDoesNotExist(bytes32 leagueId);
    error SeasonAlreadyExists(bytes32 leagueId, uint32 startYear);
    error SeasonDoesNotExist(bytes32 leagueId, uint256 seasonIndex);
    error MatchweekAlreadyExists(bytes32 leagueId, uint256 seasonIndex, uint32 mwNumber);
    error MatchweekDoesNotExist(bytes32 leagueId, uint256 seasonIndex, uint256 mwIndex);
    error CupAlreadyExists(bytes32 leagueId, uint256 seasonIndex, bytes32 cupId);
    error CupDoesNotExist(bytes32 leagueId, uint256 seasonIndex, uint256 cupIndex);
    error RoundAlreadyExists(bytes32 leagueId, uint256 seasonIndex, uint256 cupIndex, uint32 roundNumber);
    error RoundDoesNotExist(bytes32 leagueId, uint256 seasonIndex, uint256 cupIndex, uint256 roundIndex);
    error InvalidTimeRange(uint64 startTime, uint64 endTime);

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /**
     * @param initialOwner Contract owner. Should be `LifecycleTimelock` at deployment.
     */
    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    // --------------------------------------------
    //  Writes
    // --------------------------------------------

    /**
     * @notice Registers a new league and binds its PBR treasury deployment.
     * @param leagueId Unique tournament / league identifier.
     * @param pbrTreasury Deployed PBRTreasury for this league.
     */
    function createTournament(bytes32 leagueId, address pbrTreasury) external onlyOwner {
        if (leagueId == bytes32(0)) revert ZeroId();
        if (pbrTreasury == address(0)) revert ZeroAddress();
        if (_tournaments[leagueId].pbrTreasury != address(0)) revert TournamentAlreadyExists(leagueId);

        _tournaments[leagueId].pbrTreasury = pbrTreasury;

        emit TournamentCreated(leagueId, pbrTreasury);
    }

    // --------------------------------------------
    //  Domestic League
    // --------------------------------------------

    /**
     * @notice Appends a season (with optional initial matchweeks) to an existing league.
     * @param leagueId Target tournament.
     * @param startYear Season start year (unique per league).
     * @param matchweeks Initial matchweek calendar; may be empty and filled later via `addMatchweek`.
     */
    function addSeason(bytes32 leagueId, uint32 startYear, Matchweek[] calldata matchweeks) external onlyOwner {
        Tournament storage tournament = _requireTournament(leagueId);
        if (_findSeasonIndex(tournament, startYear) != type(uint256).max) {
            revert SeasonAlreadyExists(leagueId, startYear);
        }

        uint256 seasonIndex = tournament.seasons.length;
        Season storage season = tournament.seasons.push();
        season.startYear = startYear;

        uint256 matchweekCount = matchweeks.length;
        for (uint256 i; i < matchweekCount; ++i) {
            _pushMatchweek(leagueId, seasonIndex, season, matchweeks[i]);
        }

        emit SeasonAdded(leagueId, startYear, seasonIndex);
    }

    /**
     * @notice Appends a single matchweek to an existing season.
     */
    function addMatchweek(bytes32 leagueId, uint256 seasonIndex, Matchweek calldata matchweek) external onlyOwner {
        Season storage season = _requireSeason(leagueId, seasonIndex);
        _pushMatchweek(leagueId, seasonIndex, season, matchweek);
    }

    /**
     * @notice Appends multiple matchweeks to an existing season in one call.
     */
    function addMatchweeks(bytes32 leagueId, uint256 seasonIndex, Matchweek[] calldata matchweeks) external onlyOwner {
        Season storage season = _requireSeason(leagueId, seasonIndex);
        uint256 matchweekCount = matchweeks.length;
        for (uint256 i; i < matchweekCount; ++i) {
            _pushMatchweek(leagueId, seasonIndex, season, matchweeks[i]);
        }
    }

    // --------------------------------------------
    //  Update mwStartTime / mwEndTime
    // --------------------------------------------

    /**
     * @notice Updates only `mwStartTime` / `mwEndTime` for a registered matchweek.
     */
    function updateMatchweekTimes(
        bytes32 leagueId,
        uint256 seasonIndex,
        uint256 mwIndex,
        uint64 mwStartTime,
        uint64 mwEndTime
    ) external onlyOwner {
        _validateTimeRange(mwStartTime, mwEndTime);
        Matchweek storage matchweek = _requireMatchweek(leagueId, seasonIndex, mwIndex);

        matchweek.mwStartTime = mwStartTime;
        matchweek.mwEndTime = mwEndTime;

        emit MatchweekTimesUpdated(leagueId, seasonIndex, mwIndex, mwStartTime, mwEndTime);
    }

    // --------------------------------------------
    //  Domestic Cups
    // --------------------------------------------

    /**
     * @notice Appends a domestic cup (empty round list) to an existing season.
     */
    function addCup(bytes32 leagueId, uint256 seasonIndex, bytes32 cupId) external onlyOwner {
        if (cupId == bytes32(0)) revert ZeroId();
        Season storage season = _requireSeason(leagueId, seasonIndex);
        if (_findCupIndex(season, cupId) != type(uint256).max) {
            revert CupAlreadyExists(leagueId, seasonIndex, cupId);
        }

        uint256 cupIndex = season.domesticCups.length;
        Cup storage cup = season.domesticCups.push();
        cup.cupId = cupId;

        emit CupAdded(leagueId, seasonIndex, cupId, cupIndex);
    }

    /**
     * @notice Appends a round to an existing cup.
     */
    function addRound(bytes32 leagueId, uint256 seasonIndex, uint256 cupIndex, Round calldata round) external onlyOwner {
        Cup storage cup = _requireCup(leagueId, seasonIndex, cupIndex);
        _validateTimeRange(round.roundStartTime, round.roundEndTime);

        if (_findRoundIndex(cup, round.roundNumber) != type(uint256).max) {
            revert RoundAlreadyExists(leagueId, seasonIndex, cupIndex, round.roundNumber);
        }

        uint256 roundIndex = cup.rounds.length;
        cup.rounds.push(round);

        emit RoundAdded(leagueId, seasonIndex, cupIndex, round.roundNumber, roundIndex);
    }

    /**
     * @notice Updates only `roundStartTime` / `roundEndTime` for a registered cup round.
     */
    function updateRoundTimes(
        bytes32 leagueId,
        uint256 seasonIndex,
        uint256 cupIndex,
        uint256 roundIndex,
        uint64 roundStartTime,
        uint64 roundEndTime
    ) external onlyOwner {
        _validateTimeRange(roundStartTime, roundEndTime);
        Round storage round = _requireRound(leagueId, seasonIndex, cupIndex, roundIndex);

        round.roundStartTime = roundStartTime;
        round.roundEndTime = roundEndTime;

        emit RoundTimesUpdated(leagueId, seasonIndex, cupIndex, roundIndex, roundStartTime, roundEndTime);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @notice Returns scalar tournament fields (`seasons` excluded — use typed helpers).
    function getTournament(bytes32 leagueId) external view returns (address pbrTreasury, uint256 seasonCount) {
        Tournament storage tournament = _requireTournament(leagueId);
        return (tournament.pbrTreasury, tournament.seasons.length);
    }

    function getSeasonCount(bytes32 leagueId) external view returns (uint256) {
        return _requireTournament(leagueId).seasons.length;
    }

    function getSeason(bytes32 leagueId, uint256 seasonIndex)
        external
        view
        returns (uint32 startYear, uint256 matchweekCount, uint256 cupCount)
    {
        Season storage season = _requireSeason(leagueId, seasonIndex);
        return (season.startYear, season.matchweeks.length, season.domesticCups.length);
    }

    function getMatchweek(bytes32 leagueId, uint256 seasonIndex, uint256 mwIndex)
        external
        view
        returns (Matchweek memory)
    {
        return _requireMatchweek(leagueId, seasonIndex, mwIndex);
    }

    function getCup(bytes32 leagueId, uint256 seasonIndex, uint256 cupIndex)
        external
        view
        returns (bytes32 cupId, uint256 roundCount)
    {
        Cup storage cup = _requireCup(leagueId, seasonIndex, cupIndex);
        return (cup.cupId, cup.rounds.length);
    }

    function getRound(bytes32 leagueId, uint256 seasonIndex, uint256 cupIndex, uint256 roundIndex)
        external
        view
        returns (Round memory)
    {
        return _requireRound(leagueId, seasonIndex, cupIndex, roundIndex);
    }

    function tournamentExists(bytes32 leagueId) external view returns (bool) {
        return _tournaments[leagueId].pbrTreasury != address(0);
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _requireTournament(bytes32 leagueId) internal view returns (Tournament storage tournament) {
        tournament = _tournaments[leagueId];
        if (tournament.pbrTreasury == address(0)) revert TournamentDoesNotExist(leagueId);
    }

    function _requireSeason(bytes32 leagueId, uint256 seasonIndex) internal view returns (Season storage season) {
        Tournament storage tournament = _requireTournament(leagueId);
        if (seasonIndex >= tournament.seasons.length) revert SeasonDoesNotExist(leagueId, seasonIndex);
        season = tournament.seasons[seasonIndex];
    }

    function _requireMatchweek(bytes32 leagueId, uint256 seasonIndex, uint256 mwIndex)
        internal
        view
        returns (Matchweek storage matchweek)
    {
        Season storage season = _requireSeason(leagueId, seasonIndex);
        if (mwIndex >= season.matchweeks.length) revert MatchweekDoesNotExist(leagueId, seasonIndex, mwIndex);
        matchweek = season.matchweeks[mwIndex];
    }

    function _requireCup(bytes32 leagueId, uint256 seasonIndex, uint256 cupIndex) internal view returns (Cup storage cup) {
        Season storage season = _requireSeason(leagueId, seasonIndex);
        if (cupIndex >= season.domesticCups.length) revert CupDoesNotExist(leagueId, seasonIndex, cupIndex);
        cup = season.domesticCups[cupIndex];
    }

    function _requireRound(bytes32 leagueId, uint256 seasonIndex, uint256 cupIndex, uint256 roundIndex)
        internal
        view
        returns (Round storage round)
    {
        Cup storage cup = _requireCup(leagueId, seasonIndex, cupIndex);
        if (roundIndex >= cup.rounds.length) {
            revert RoundDoesNotExist(leagueId, seasonIndex, cupIndex, roundIndex);
        }
        round = cup.rounds[roundIndex];
    }

    function _pushMatchweek(bytes32 leagueId, uint256 seasonIndex, Season storage season, Matchweek calldata matchweek)
        internal
    {
        _validateTimeRange(matchweek.mwStartTime, matchweek.mwEndTime);
        if (_findMatchweekIndex(season, matchweek.mwNumber) != type(uint256).max) {
            revert MatchweekAlreadyExists(leagueId, seasonIndex, matchweek.mwNumber);
        }

        uint256 mwIndex = season.matchweeks.length;
        season.matchweeks.push(matchweek);
        emit MatchweekAdded(leagueId, seasonIndex, matchweek.mwNumber, mwIndex);
    }

    function _findSeasonIndex(Tournament storage tournament, uint32 startYear) internal view returns (uint256) {
        uint256 length = tournament.seasons.length;
        for (uint256 i; i < length; ++i) {
            if (tournament.seasons[i].startYear == startYear) return i;
        }
        return type(uint256).max;
    }

    function _findMatchweekIndex(Season storage season, uint32 mwNumber) internal view returns (uint256) {
        uint256 length = season.matchweeks.length;
        for (uint256 i; i < length; ++i) {
            if (season.matchweeks[i].mwNumber == mwNumber) return i;
        }
        return type(uint256).max;
    }

    function _findCupIndex(Season storage season, bytes32 cupId) internal view returns (uint256) {
        uint256 length = season.domesticCups.length;
        for (uint256 i; i < length; ++i) {
            if (season.domesticCups[i].cupId == cupId) return i;
        }
        return type(uint256).max;
    }

    function _findRoundIndex(Cup storage cup, uint32 roundNumber) internal view returns (uint256) {
        uint256 length = cup.rounds.length;
        for (uint256 i; i < length; ++i) {
            if (cup.rounds[i].roundNumber == roundNumber) return i;
        }
        return type(uint256).max;
    }

    function _validateTimeRange(uint64 startTime, uint64 endTime) internal pure {
        if (endTime <= startTime) revert InvalidTimeRange(startTime, endTime);
    }
}
