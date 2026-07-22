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
    uint16 earliestSeasonStartYear;
    Position expectedPosition;
    uint256 birthDate;
    SeasonMinutes[] seasonMinutes;
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
 * @notice CRE squad-fill report.
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

/// @dev Previous-season minute thresholds (ported from the original Supabase eligibility edge fn).
uint32 constant THRESHOLD_GK = 361;
uint32 constant THRESHOLD_UNDER_21 = 181;
uint32 constant THRESHOLD_OUTFIELD = 901;
uint256 constant UNDER_21_AGE = 21;

/// @notice Eligibility cohort a candidate falls into (priority: GK → under-21 → outfield).
enum EligibilityBucket {
    None,
    Goalkeeper,
    Under21,
    Outfield
}

/// @notice Eligible, undeployed players grouped by cohort (from one `verifyEligibility` page).
struct EligibilityGroups {
    bytes32[] goalkeepers;
    bytes32[] under21;
    bytes32[] outfield;
}
