// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Position } from "@types/PlayerSetTypes.sol";

// =============================================================================
//  EligibilityTypes (eligibility-3)
//
//  Single CRE squads workflow, multiple handlers:
//    - EVM log: SeasonsQueued / SeasonReady / FetchContinue / TransientComplete /
//               SortPage / PopulationComplete (info) / LoopPending
//    - Cron:    gated current-season fetch (mutex vs historical)
//
//  Unit of work = one seasonId at a time:
//    1) Append FETCH page-slices into TransientReturn until the season is complete
//       (SP page ≈ one club; CRE may stay-on-page and drain that club in slices)
//    2) SORT the full season snapshot: upsert MinutesStore → rebuild SquadList →
//       removal pass (absent from TransientReturn membership)
//    3) Clear buffer; auto-advance to the next seasonId (onchain — no CRE bookkeeping)
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

/// @dev `SortCursor.step` — upsert MinutesStore + rebuild SquadLists from buffer.
uint8 constant SORT_STEP_UPSERT = 0;

/// @dev `SortCursor.step` — removal pass over prior-roster candidates.
uint8 constant SORT_STEP_REMOVALS = 1;

// --------------------------------------------
//  Squad workflow — status & phases
// --------------------------------------------

/// @notice Per-`seasonId` lifecycle for squad ingest.
/// @dev Historical seasons end at `ARTIFACT`. Current seasons cycle
///      `IDLE → TRANSIENT → IDLE`. `TRANSIENT` means the full-season buffer is
///      ready (or being sorted) — not “one HTTP page landed”. Last SORT chunk
///      auto-finalizes (`IDLE` / `ARTIFACT`); there is no separate finalize phase.
enum RunStatus {
    IDLE,
    TRANSIENT,
    ARTIFACT
}

/// @notice CRE → `_processReport` discriminator.
/// @dev `FETCH_TRANSIENT` carries a **page slice** (store appends).
///      `SORT_TRANSIENT` is report-only (no HTTP); gas-chunked via `SortPage`.
enum SquadPhase {
    FETCH_TRANSIENT,
    SORT_TRANSIENT
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
///      `pass == None`. Exactly one `(activeLeagueId, activeSeasonId)` in flight.
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
/// @dev Historical: seasons oldest→newest under `activeLeagueIndex`, each fully
///      (fetch→sort→finalize) before the next. Current: same rule, but only rows
///      with `seasonStartYear == WorkflowControl.currentSeasonStartYear`.
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
 * @dev Built incrementally: SP `_pgNm` ≈ one club; CRE may split that club across
 *      multiple ~5KB reports (**stay-on-page**). `personsOffset` is the within-page
 *      cursor that makes stay-on-page idempotent under CRE retries.
 *
 *      Append rules (`FETCH_TRANSIENT`):
 *        - Slice `personsOffset` must equal the buffer’s current offset.
 *        - Append parallel arrays; `personsOffset += slice.length`.
 *        - `nextPage == pageFetched`: club not fully drained — stay on SP page.
 *        - `nextPage == pageFetched+1` or `DONE`: club drained — reset offset to 0.
 *        - Never SORT a partial season; never hold two seasons at once.
 *
 *      Sort rules (`SORT_TRANSIENT`):
 *        - Only when `nextPage == DONE` (`RunStatus.TRANSIENT`).
 *        - (1) Upsert → MinutesStore (club/league change detection).
 *        - (2) Rebuild SquadList per club from the buffer.
 *        - (3) Removals: prior roster ∩ ∉ buffer membership.
 *        - Auto-finalize: clear buffer; season → `IDLE` or `ARTIFACT`.
 */
struct TransientReturn {
    /// @dev SP `_pgNm` currently being drained (0 if buffer empty).
    uint16 pageFetched;
    /// @dev Next SP page CRE should request, or `SQUAD_FETCH_PAGE_DONE`.
    uint16 nextPage;
    /// @dev Persons already accepted on `pageFetched` (buffer) / slice start (report).
    uint16 personsOffset;
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
/// @dev `step` is `SORT_STEP_UPSERT` then `SORT_STEP_REMOVALS`. Paging is gas-only.
struct SortCursor {
    bool active;
    bytes32 leagueId;
    bytes32 seasonId;
    /// @dev `SORT_STEP_UPSERT` | `SORT_STEP_REMOVALS`.
    uint8 step;
    /// @dev Offset into buffer arrays (upsert) or removal-candidate array.
    uint32 offset;
}

/// @notice Unified CRE report decode target for all squad handlers.
/// @dev `FETCH_TRANSIENT`: `data` is one page slice (store appends).
///      `SORT_TRANSIENT`: `data` empty; `leagueId` + `seasonId` select active work.
struct SquadReport {
    SquadPhase phase;
    bytes32 leagueId;
    bytes32 seasonId;
    /// @dev Page slice on FETCH only; ignored on SORT.
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
/// @dev `currentLeagueId` / `currentClubId` detect transfers on SORT upsert.
///      Removals (absent from season TransientReturn) clear club membership and
///      stage the player for downstream TransferLocker handling.
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
///      League/season advance is **onchain-automated**: no CRE bookkeeping handler.
library SquadWorkflowEvents {
    /// @notice League seasons queued — start/resume historical fetch for `leagueId`.
    event SeasonsQueued(bytes32 indexed leagueId, uint16 seasonCount);

    /// @notice Next `seasonId` is ready to fetch (same or cross-league current pass).
    /// @dev Separation from `FetchContinue`: new season always starts at page 1 / offset 0.
    event SeasonReady(bytes32 indexed leagueId, bytes32 indexed seasonId);

    /// @notice More FETCH work remains for the **same** season (HTTP / report budget).
    /// @dev `nextPage` = SP `_pgNm` to request (or current page when staying).
    ///      `personsOffset` = within-page resume cursor (0 after a page advances).
    event FetchContinue(bytes32 indexed leagueId, bytes32 indexed seasonId, uint16 nextPage, uint16 personsOffset);

    /// @notice Full-season `TransientReturn` complete for `seasonId` → start SORT.
    event TransientComplete(bytes32 indexed leagueId, bytes32 indexed seasonId);

    /// @notice More SORT gas-chunks remain (`step` = upsert or removals).
    event SortPage(bytes32 indexed leagueId, bytes32 indexed seasonId, uint8 step, uint32 offset);

    /// @notice All seasons under `leagueId` for the active pass are finalized.
    /// @dev Informational. Next league is woken by `SeasonsQueued` in the same tx
    ///      (or `LoopPending` if the book is terminal) — no CRE `onLeagueAdvance`.
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
