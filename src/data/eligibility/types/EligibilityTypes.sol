// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Position } from "@base/global/types/PlayerSetTypes.sol";

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

/// @notice Per-player eligibility store; name/symbol deferred to DeployDoppler.
struct MinutesStore {
    /// @dev Season start year of the squad-fill report that first created this player (set once).
    uint16 earliestSeasonStartYear;
    Position expectedPosition;
    uint256 birthDate;
    SeasonMinutes[] seasonMinutes;
    /// @dev Σ mins * λ^age, WAD-scaled. Written only by `verifyEligibility` (full replay).
    uint256 weightedScoreWad;
    /// @dev Global round index G at last `verifyEligibility` recompute for this player.
    uint32 scoreAsOfGlobalRound;
}

/// @notice Minutes for one competition calendar (`seasonId` = HPID of tournamentCalendarUuid).
struct SeasonMinutes {
    bytes32 seasonId; // tournamentCalendar
    uint16 seasonStartYear;
    uint32 totalMinutes;
    Appearance[] appearances;
    uint32[POSITION_COUNT] minsByPosition;
}

// --------------------------------------------
//  Reports
// --------------------------------------------

/// @notice Single-match appearance delta; season is passed once per `recordAppearances` batch.
struct Appearance {
    bytes32 playerId;
    uint32 roundNumber;
    Position position;
    uint32 minsPlayed;
}

/**
 * @notice CRE squad-fill report payload (`abi.decode` target in `_processReport`).
 * @dev Wire layout matches the flat tuple CRE encodes; field order is the ABI.
 */
struct SquadFillReport {
    bytes32 seasonId;
    uint16 seasonStartYear;
    uint16 pageFetched;
    uint16 nextPage;
    bytes32[] playerIds;
    uint256[] birthDates;
}

// --------------------------------------------
//  Eligibility Criteria
// --------------------------------------------

/// @dev Fixed-point scale for `weightedScoreWad` / `LAMBDA_WAD`.
uint256 constant SCORE_WAD = 1e18;

/// @dev λ = 0.97 — half-life ≈ ln(0.5)/ln(0.97) ≈ 23 rounds.
uint256 constant LAMBDA_WAD = 97e16;

/// @dev Effective-minute thresholds (compare to `liveScoreWad / SCORE_WAD`).
uint32 constant THRESHOLD_GK = 361;
uint32 constant THRESHOLD_UNDER_21 = 181;
uint32 constant THRESHOLD_OUTFIELD = 901;
/// @dev newTransfer / backFromLoan share this threshold (no onchain distinction).
uint32 constant THRESHOLD_NEW_TRANSFER = 1;
uint256 constant UNDER_21_AGE = 21;

/// @notice Eligibility cohort a candidate falls into.
/// @dev Priority: newTransfer/backFromLoan → GK → under-21 → outfield.
///
///      newTransfer / backFromLoan predicate (DeployDoppler flag):
///        `weightedScoreWad == 0 && earliestSeasonStartYear == currentSeasonYear`
///      After the first league-weighted minute, `weightedScoreWad > 0`, but the player remains in
///      this cohort for the season while `earliestSeasonStartYear == currentSeasonYear` so
///      DeployDoppler still receives the flag once they clear `THRESHOLD_NEW_TRANSFER`.
enum EligibilityBucket {
    None,
    Goalkeeper,
    Under21,
    Outfield,
    /// @dev Shared flag for newTransfer and backFromLoan (identical onchain predicate).
    NewTransfer
}

/// @notice Eligible, undeployed players grouped by cohort (from one `verifyEligibility` page).
/// @dev `newTransfers` carries the DeployDoppler newTransfer / backFromLoan flag.
struct EligibilityGroups {
    bytes32[] goalkeepers;
    bytes32[] under21;
    bytes32[] outfield;
    bytes32[] newTransfers;
}
