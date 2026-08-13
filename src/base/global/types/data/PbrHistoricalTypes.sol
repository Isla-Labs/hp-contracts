// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { SeasonRef } from "@types/data/RoundManagerTypes.sol";
import { Position } from "@types/registries/PlayerSetTypes.sol";

/**
 * @title PbrHistoricalTypes
 * @notice Historical DMS backfill — Settle-style per-fixture fan-out within each round.
 */

/// @notice Tournament-level historical DMS phase.
enum HistoricalDmsPhase {
    None,
    /// @dev Walking seasons / rounds; each round fans out ≤10 fixture jobs.
    Running,
    /// @dev All bootstrap fixtures ingested.
    Complete
}

/// @notice Per-fixture job phase (mirrors `PbrSettle.FixturePhase`).
enum HistoricalFixturePhase {
    None,
    Requested,
    Done
}

/**
 * @notice Single-match appearance delta for `SquadStore.recordAppearances`.
 * @dev Written on domestic fulfills only; always staged here for digests / views.
 */
struct Appearance {
    bytes32 fixtureId;
    bytes32 playerId;
    uint32 roundNumber;
    Position position;
    uint32 minsPlayed;
}

/**
 * @notice Per-tournament historical DMS cursor (seasons ascending by start year).
 * @dev Active round tracks `fixturesExpected` / `fixturesDone` like `RoundSettlement`.
 */
struct TournamentHistoricalDms {
    HistoricalDmsPhase phase;
    uint32 seasonIndex;
    /// @dev 1-based round currently fanned out.
    uint32 roundNumber;
    uint32 fixturesExpected;
    uint32 fixturesDone;
    /// @dev Cached at open: `DOMESTIC_LEAGUE` → write Appearances to SquadStore.
    bool writeAppearances;
    SeasonRef[] seasons;
}

/// @notice In-flight oracle binding for one fixture job.
struct PendingHistorical {
    bytes32 tournamentId;
    bytes32 seasonId;
    uint16 seasonStartYear;
    uint32 roundNumber;
    bytes32 fixtureId;
}

/// @notice Per-fixture progress under a round.
struct HistoricalFixtureJob {
    HistoricalFixturePhase phase;
    bytes32 fixtureId;
    bytes32 requestId;
}
