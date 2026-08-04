// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundSchedule } from "@types/TournamentTypes.sol";

/**
 * @title IRoundManager
 * @notice Round-calendar SoT (finalRound + RoundSchedule rows) — separate from TournamentRegistry seasons.
 */
interface IRoundManager {
    // --------------------------------------------
    //  Writes — owner (Orchestrator)
    // --------------------------------------------

    /// @notice Set / replace `finalRound` for a registry-opened season. Reverts if `finalRound == 0`.
    function setFinalRound(bytes32 tournamentId, uint16 seasonStartYear, uint32 finalRound) external;

    function upsertRound(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule calldata round) external;

    function upsertRounds(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule[] calldata rounds) external;

    // --------------------------------------------
    //  Views
    // --------------------------------------------

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
