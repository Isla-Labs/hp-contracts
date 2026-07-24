// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Position } from "@types/PlayerSetTypes.sol";

// --------------------------------------------
//  Utils
// --------------------------------------------

/// @dev `Position` has 14 variants (GK … ST); index = `uint8(Position)`.
uint256 constant POSITION_COUNT = 14;

/// @dev Sentinel in `squadFillPage[seasonId]`: season sweep is complete.
///      Historical seasons stay here; daily-active seasons may restart from page 1 after an interval.
uint16 constant SQUAD_FILL_PAGE_DONE = 1000;

// --------------------------------------------
//  Core
// --------------------------------------------

/// @notice Per-player eligibility store (CRE may fill `name` / `symbol` after create).
/// @dev `weightedScoreWad` is maintained incrementally in `recordAppearances` and decayed
///      to `G_now` in `verifyEligibility` (`lastScoreGlobalRound` is the score's G-basis).
struct MinutesStore {
    string name;
    string symbol;
    uint16 earliestSeasonStartYear;
    Position expectedPosition;
    uint256 birthDate;
    SeasonMinutes[] seasonMinutes;
    uint256 weightedScoreWad;
    /// @dev Global round that `weightedScoreWad` is normalized to (`0` = never scored).
    uint32 lastScoreGlobalRound;
}

/// @notice Aggregate minutes for one competition calendar (`seasonId` = tournamentCalendar HPID).
/// @dev Per-match rows are not retained; score uses incremental decay, position uses minsByPosition.
struct SeasonMinutes {
    bytes32 seasonId; // tournamentCalendar
    uint16 seasonStartYear;
    uint32 totalMinutes;
    uint32[POSITION_COUNT] minsByPosition;
}

/// @notice Latest active squad membership for one club (`clubId` = HPID of contestantUuid).
struct SquadList {
    bytes32 clubId;
    bytes32[] playerIds;
}

// --------------------------------------------
//  Reports
// --------------------------------------------

/// @notice Single-match appearance delta for `recordAppearances` (not persisted onchain).
/// @dev Season is passed once per batch; only domestic-league rows update `weightedScoreWad`.
struct Appearance {
    bytes32 playerId;
    uint32 roundNumber;
    Position position;
    uint32 minsPlayed;
}

/**
 * @notice CRE squad-fill report payload (`abi.decode` target in `_processReport`).
 * @dev Wire layout matches the flat tuple CRE encodes; field order is the ABI.
 *      Historical: `clubId = 0`, `squadPlayerIds` empty (create-only).
 *      Daily-active: `clubId` + full active `squadPlayerIds` for membership overwrite.
 *      Optional metadata: `metaPlayerIds` / `names` / `symbols` (parallel; length 0 = skip).
 *      Used on create (historical / quiet) and on quiet resweeps to backfill existing rows.
 */
struct SquadFillReport {
    bytes32 seasonId;
    uint16 seasonStartYear;
    uint16 pageFetched;
    uint16 nextPage;
    bytes32[] playerIds;
    uint256[] birthDates;
    /// @dev HPID(contestantUuid). Zero skips membership sync (historical path).
    bytes32 clubId;
    /// @dev Full active squad for `clubId` (not just newly created players).
    bytes32[] squadPlayerIds;
    /// @dev Players receiving `name` / `symbol` this report (may overlap `playerIds`).
    bytes32[] metaPlayerIds;
    string[] names;
    string[] symbols;
}

// --------------------------------------------
//  Score math (fixed; not governance-tunable)
// --------------------------------------------

/// @dev Fixed-point scale for `weightedScoreWad` / `LAMBDA_WAD`.
uint256 constant SCORE_WAD = 1e18;

/// @dev λ = 0.97 — half-life ≈ ln(0.5)/ln(0.97) ≈ 23 rounds.
uint256 constant LAMBDA_WAD = 97e16;

// Cohort thresholds live in `EligibilityCriteria` (CATEGORY_ONE updatable).

/// @notice Eligibility cohort a candidate falls into.
/// @dev Priority: newTransfer/backFromLoan → GK → under-21 → outfield.
///      newTransfer / backFromLoan: `earliestSeasonStartYear == currentSeasonYear` (DeployDoppler flag).
enum EligibilityBucket {
    None,
    Goalkeeper,
    Under21,
    Outfield,
    NewTransfer
}

/// @notice Results from one `verifyEligibility` page.
/// @dev Deploy cohorts (`goalkeepers`…`newTransfers`) → DopplerLocker waiting room.
///      `toDeactivate` / `toReactivate` → TransferLocker waiting room.
struct EligibilityGroups {
    bytes32[] goalkeepers;
    bytes32[] under21;
    bytes32[] outfield;
    bytes32[] newTransfers;
    /// @dev Deployed + not `INACTIVE` + below GK/u21/outfield continuity threshold.
    bytes32[] toDeactivate;
    /// @dev Deployed + `INACTIVE` + back above GK/u21/outfield continuity threshold.
    bytes32[] toReactivate;
}
