// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Position } from "@types/PlayerSetTypes.sol";

// =============================================================================
//  EligibilityTypes (eligibility-3)
//
//  Ground-up shape for a single CRE squads workflow with multiple handlers:
//    - EVM log: seasons queued / fetch continue / TransientComplete / SortPage /
//               PopulationComplete
//    - Cron:    gated current-season fetch (mutual exclusion vs historical)
//
//  Unit of work = one seasonId at a time:
//    1) Append FETCH pages into TransientReturn until the season is complete
//    2) SORT that full season snapshot into MinutesStore / SquadList
//    3) Clear buffer; advance to the next seasonId (overwrite)
//
//  Compare against `eligibility-2/types/EligibilityTypes.sol` (preliminary).
// =============================================================================

// --------------------------------------------
//  Constants
// --------------------------------------------

/// @dev `Position` has 14 variants (GK … ST); index = `uint8(Position)`.
uint256 constant POSITION_COUNT = 14;

/// @dev Fixed-point scale for `weightedScoreWad` / `LAMBDA_WAD`.
uint256 constant SCORE_WAD = 1e18;

/// @dev λ = 0.97 — half-life ≈ ln(0.5)/ln(0.97) ≈ 23 rounds.
uint256 constant LAMBDA_WAD = 97e16;

/// @dev Sentinel `nextPage` when the SP season sweep has no further pages.
uint16 constant SQUAD_FETCH_PAGE_DONE = 1000;

// --------------------------------------------
//  Squad workflow — status & phases
// --------------------------------------------

/// @notice Per-`seasonId` lifecycle for squad ingest.
/// @dev Historical seasons end at `ARTIFACT`. Current seasons cycle
///      `IDLE → TRANSIENT → POPULATED → IDLE`.
///      `TRANSIENT` means the full-season `TransientReturn` buffer is ready
///      (or being sorted) — not “one HTTP page landed”.
enum RunStatus {
    IDLE,
    TRANSIENT,
    POPULATED,
    ARTIFACT
}

/// @notice CRE → `_processReport` discriminator (prefer enum over bool).
/// @dev `FETCH_TRANSIENT` carries a **page slice** that the store **appends**
///      into the season buffer. `SORT_TRANSIENT` / `FINALIZE` are no-HTTP.
enum SquadPhase {
    FETCH_TRANSIENT,
    SORT_TRANSIENT,
    FINALIZE
}

/// @notice Which pass owns the single-slot work buffers.
/// @dev Mutual exclusion: historical and current must not share
///      `TransientReturn` / `SortCursor` concurrently.
enum PassKind {
    None,
    Historical,
    Current
}

// --------------------------------------------
//  Squad workflow — control & bookkeeping
// --------------------------------------------

/// @notice Global mutex / pass pointer for the squads workflow.
/// @dev `historicalActive == (pass == Historical)`. Cron no-ops unless
///      `pass == None` and every tracked season is `IDLE` or `ARTIFACT`.
///      Exactly one `(activeLeagueId, activeSeasonId)` is in flight at a time.
struct WorkflowControl {
    PassKind pass;
    bool historicalActive;
    /// @dev League currently being processed; `bytes32(0)` if none.
    bytes32 activeLeagueId;
    /// @dev Index into `RunBook.leagueIds`.
    uint16 activeLeagueIndex;
    /// @dev Season currently filling or sorting `TransientReturn`; `0` if none.
    bytes32 activeSeasonId;
    /// @dev Index into `RunBook.seasons[activeLeagueIndex]`.
    uint16 activeSeasonIndex;
    /// @dev UTC calendar year used for current-season selection (set by store/ops).
    uint16 currentSeasonStartYear;
}

/// @notice Indexed season under a league.
struct SeasonRun {
    bytes32 seasonId;
    uint16 seasonStartYear;
    RunStatus status;
}

/// @notice All leagues/seasons the squads workflow tracks.
/// @dev Historical: process seasons oldest→newest under `activeLeagueIndex`,
///      one season fully (fetch→sort→finalize) before the next. Then advance
///      league. Current: same sequential season rule, but only rows whose
///      `seasonStartYear == WorkflowControl.currentSeasonStartYear`.
struct RunBook {
    uint16 runNumber;
    bytes32[] leagueIds;
    /// @dev `seasons[leagueIndex][seasonIndex]`
    SeasonRun[][] seasons;
}

// --------------------------------------------
//  Squad workflow — full-season transient buffer
// --------------------------------------------

/**
 * @notice Full-season staging object for one `seasonId` (single global slot).
 * @dev Built incrementally because CRE cannot return an entire SP squads
 *      endpoint in one report (~5KB) / one execution (HTTP caps).
 *
 *      Append rules (`FETCH_TRANSIENT`):
 *        - If `data.seasonId == buffer.seasonId` (same active season):
 *          append parallel arrays; advance `pageFetched` / `nextPage`.
 *        - If `data.seasonId` differs (next season after prior sort+clear):
 *          replace/reset the buffer, then append the first page.
 *        - Never SORT a partial season; never hold two seasons at once.
 *
 *      Sort rules (`SORT_TRANSIENT`):
 *        - Runs only when fetch hit `SQUAD_FETCH_PAGE_DONE` for this season
 *          (`RunStatus.TRANSIENT`). Upserts the **full** snapshot into
 *          `MinutesStore` / `SquadList` so club & league transfers can be
 *          detected coherently. May page via `SortCursor` + `SortPage` for gas.
 *        - After sort completes: clear buffer; season → `POPULATED` → finalize.
 */
struct TransientReturn {
    uint16 pageFetched;
    uint16 nextPage;
    bytes32 leagueId;
    bytes32 seasonId;
    uint16 seasonStartYear;
    bytes32[] playerIds;
    bytes32[] clubIds;
    string[] playerNames;
    string[] playerSymbols;
    uint32[] birthDates;
}

/// @notice Onchain sort pagination cursor over the **full-season** buffer.
/// @dev SORT is still season-scoped; paging is only for gas, not for HTTP.
///      After each SORT chunk, if work remains, emit `SortPage` so CRE
///      re-enters with `SquadPhase.SORT_TRANSIENT` (no HTTP).
struct SortCursor {
    bool active;
    bytes32 leagueId;
    bytes32 seasonId;
    /// @dev Offset into `TransientReturn` parallel arrays (or club walk).
    uint32 offset;
}

/// @notice Unified CRE report decode target for all squad handlers.
/// @dev `FETCH_TRANSIENT`: `data` is one **page slice** (store appends).
///      `SORT_TRANSIENT` / `FINALIZE`: `data` empty; `leagueId` + `seasonId`
///      select the active buffer / book row.
struct SquadReport {
    SquadPhase phase;
    bytes32 leagueId;
    bytes32 seasonId;
    /// @dev Page slice on FETCH only; ignored on SORT / FINALIZE.
    TransientReturn data;
}

// --------------------------------------------
//  Persistent storage shapes
// --------------------------------------------

/// @notice Latest active squad membership for one club.
struct SquadList {
    bytes32 clubId;
    bytes32[] playerIds;
}

/// @notice Per-player eligibility / minutes store.
struct MinutesStore {
    bytes32 currentLeagueId;
    bytes32 currentClubId;
    string name;
    string symbol;
    uint32 birthDate;
    Position expectedPosition;
    uint32[POSITION_COUNT] positionMinutes;
    LeagueMinutes[] leagueMinutes;
}

struct LeagueMinutes {
    bytes32 leagueId;
    uint256 weightedScoreWad;
    uint32 lastScoreGlobalRound;
}

// --------------------------------------------
//  Squad workflow — events (CRE log triggers)
// --------------------------------------------

/// @dev Emitted by EligibilityStore. Topic0 drives CRE handlers.
library SquadWorkflowEvents {
    /// @notice League seasons queued for historical squad backfill.
    /// @dev Prefer store-owned queue event over raw `TournamentCreated`.
    event SeasonsQueued(bytes32 indexed leagueId, uint16 seasonCount);

    /// @notice More SP pages remain for the active season (CRE HTTP budget).
    /// @dev Wake `onHistoricalFetch` / `onCurrentFetch` to append the next page
    ///      into the same `TransientReturn` (do not SORT yet).
    event FetchContinue(bytes32 indexed leagueId, bytes32 indexed seasonId, uint16 nextPage);

    /// @notice Full-season `TransientReturn` is complete for `seasonId` → start SORT.
    /// @dev Season-scoped (not league-scoped). Emitted when `nextPage == DONE`
    ///      after the last append; sets `RunStatus.TRANSIENT`.
    event TransientComplete(bytes32 indexed leagueId, bytes32 indexed seasonId);

    /// @notice More SORT gas-chunks remain for this season’s full buffer.
    event SortPage(bytes32 indexed leagueId, bytes32 indexed seasonId, uint32 offset);

    /// @notice All seasons under `leagueId` for the active pass are finalized
    ///         (`IDLE` or `ARTIFACT`). Advance to next league or clear pass.
    event PopulationComplete(bytes32 indexed leagueId);

    /// @notice Entire `RunBook` is terminal (`IDLE`|`ARTIFACT`) and `pass == None`.
    /// @dev Optional wake; hourly cron remains the steady-state heartbeat.
    event LoopPending(uint16 runNumber);
}

// --------------------------------------------
//  PPM-Verify Workflow
// --------------------------------------------

struct Appearance {
    bytes32 leagueId;
    bytes32 playerId;
    Position position;
    uint32 minsPlayed;
}

// --------------------------------------------
//  Eligibility Buckets
// --------------------------------------------

/// @notice Which threshold a candidate falls into.
enum EligibilityBucket {
    None,
    Goalkeeper,
    Under21,
    Outfield,
    NewTransfer
}

/// @notice Change sets for DopplerLocker / TransferLocker.
struct EligibilityGroups {
    bytes32[] goalkeepers;
    bytes32[] under21;
    bytes32[] outfield;
    bytes32[] newTransfers;
    bytes32[] toDeactivate;
    bytes32[] toReactivate;
}
