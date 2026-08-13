// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { SeasonRef } from "@types/data/RoundManagerTypes.sol";
import { Position } from "@types/registries/PlayerSetTypes.sol";

/**
 * @title SquadStoreTypes
 * @notice Fetch / sort state machine + MinutesStore / verify snapshot types for `SquadStore`.
 */

/// @dev `Position` enum length (GK … ST) — must match `PlayerSetTypes.Position`.
uint256 constant POSITION_COUNT = 12;

/// @dev Fixed-point scale for `weightedScoreWad` / `LAMBDA_WAD`.
uint256 constant SCORE_WAD = 1e18;

/// @dev λ = 0.97 — half-life ≈ ln(0.5)/ln(0.97) ≈ 23 rounds.
uint256 constant LAMBDA_WAD = 97e16;

/// @dev SP `nextPage` sentinel when the season sweep has no further pages.
uint16 constant SQUAD_FETCH_PAGE_DONE = 1000;

/// @dev Players upserted / removal candidates processed per SortChunks fulfill.
uint256 constant SORT_CHUNK = 50;

uint8 constant SORT_STEP_UPSERT = 0;
uint8 constant SORT_STEP_REMOVALS = 1;

/// @notice League-level squad ingest phase (across bootstrap seasons).
enum SquadFetchPhase {
    None,
    /// @dev Walking bootstrap seasons earliest → latest.
    Historical,
    /// @dev Historical done; latest season stays queued for permissionless refresh.
    Live
}

/// @notice Per-season oracle step (separate efficient CVM jobs).
enum SeasonSquadStep {
    /// @dev Paged SP squad pull into a season buffer (`HistoricalSquadSync` / `SquadSync`).
    FetchPages,
    /// @dev Onchain apply of buffer (oracle ack only — gas stipend via fulfill).
    SortChunks
}

/**
 * @notice Per-league fetch cursor (seasons stored ascending by `seasonStartYear`).
 * @dev After historical completes, `phase = Live` and `seasonIndex` points at the latest season.
 */
struct LeagueSquadFetch {
    SquadFetchPhase phase;
    SeasonSquadStep step;
    /// @dev Index into `seasons` for the active season.
    uint32 seasonIndex;
    /// @dev 1-based SP `_pgNm` for the next `FetchPages` request.
    uint16 pageCursor;
    /// @dev Within-page person offset for stay-on-page draining.
    uint16 personsOffset;
    /// @dev `SORT_STEP_UPSERT` | `SORT_STEP_REMOVALS`.
    uint8 sortStep;
    /// @dev Chunk offset for `SortChunks`.
    uint32 sortCursor;
    bytes32 pendingRequestId;
    /// @dev Earliest bootstrap season year — G-index base for this league.
    uint16 scoreBaseYear;
    SeasonRef[] seasons;
}

/**
 * @notice Full-season staging buffer for one `seasonId` (single global slot).
 * @dev No name/symbol — metadata is resolved in the market deploy flow (`PlayerMetadata`).
 */
struct TransientReturn {
    uint16 pageFetched;
    uint16 nextPage;
    uint16 personsOffset;
    bytes32 leagueId;
    bytes32 seasonId;
    uint16 seasonStartYear;
    bytes32[] playerIds;
    bytes32[] clubIds;
    uint32[] birthDates;
}

/// @notice Oracle fetch-page response (no names/symbols).
struct SquadFetchPage {
    uint16 pageFetched;
    uint16 nextPage;
    /// @dev Slice start offset (must match store `personsOffset`).
    uint16 personsOffset;
    bytes32[] playerIds;
    bytes32[] clubIds;
    uint32[] birthDates;
}

struct SquadList {
    bytes32 clubId;
    bytes32[] playerIds;
}

/// @notice Recency-weighted minutes score for one domestic league.
struct LeagueMinutes {
    bytes32 leagueId;
    uint256 weightedScoreWad;
    uint32 lastScoreGlobalRound;
}

/// @notice Membership + career minutes + per-league rolling scores.
struct MinutesStore {
    bytes32 currentLeagueId;
    bytes32 currentClubId;
    uint32 birthDate;
    uint16 startYearCurrentLeague;
    uint64 deactivatedAt;
    Position expectedPosition;
    uint32[POSITION_COUNT] positionMinutes;
    LeagueMinutes[] leagueMinutes;
}

/// @notice Lean classify payload for `EligibilityVerifier` (current-league score only).
struct VerifySnapshot {
    bytes32 currentLeagueId;
    bytes32 currentClubId;
    uint32 birthDate;
    uint16 startYearCurrentLeague;
    Position expectedPosition;
    LeagueMinutes currentLeague;
}
