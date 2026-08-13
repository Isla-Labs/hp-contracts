// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundFetchPhase, SeasonRef, TournamentRoundFetch } from "@types/data/RoundManagerTypes.sol";
import { RoundSchedule } from "@types/registries/TournamentTypes.sol";

/**
 * @title IRoundManager
 * @notice Round-calendar fetch + SoT writes into `TournamentRegistry`.
 */
interface IRoundManager {
    // --------------------------------------------
    //  Bootstrap — Orchestrator
    // --------------------------------------------

    /**
     * @notice Arm historical → live fetch for `tournamentId` (seasons ordered earliest → latest).
     * @dev Parallel `seasonIds` / `seasonStartYears`. Per season, oracle auto-chains:
     *      `FormatRounds` (all windows) → `UpsertFixtures` pages (10 rounds / ≤100 fixtures).
     *      After all seasons complete, phase becomes `Live` (latest only).
     */
    function openTournament(
        bytes32 tournamentId,
        bytes32[] calldata seasonIds,
        uint16[] calldata seasonStartYears
    ) external returns (bytes32 requestId);

    /**
     * @notice Permissionless live refresh for the latest season only (rate-limited, default 1h).
     * @dev Requires `Live`. Opens `CvmJob.RoundSync` (calendar probe → refresh or openSeason).
     */
    function refreshRounds(bytes32 tournamentId) external returns (bytes32 requestId);

    // --------------------------------------------
    //  Writes — RoundManager → TournamentRegistry
    // --------------------------------------------

    /// @notice Set / replace `finalRound` for a registry-opened season. Reverts if `finalRound == 0`.
    function setFinalRound(bytes32 tournamentId, uint16 seasonStartYear, uint32 finalRound) external;

    function upsertRound(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule calldata round) external;

    function upsertRounds(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule[] calldata rounds) external;

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function getFetchState(bytes32 tournamentId) external view returns (TournamentRoundFetch memory);

    function getLatestSeason(bytes32 tournamentId) external view returns (SeasonRef memory);

    function getFetchPhase(bytes32 tournamentId) external view returns (RoundFetchPhase);

    function getFinalRound(bytes32 tournamentId, uint16 seasonStartYear) external view returns (uint32);

    function getRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (RoundSchedule memory);

    /// @notice True when the round exists with a valid time range and at least one fixture.
    function isRoundPublished(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (bool);
}
