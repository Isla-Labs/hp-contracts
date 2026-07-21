// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Position } from "@base/global/types/PlayerSetTypes.sol";

/// @dev `Position` has 14 variants (GK … ST); index = `uint8(Position)`.
uint256 constant POSITION_COUNT = 14;

struct MinutesStore {
    /// @dev Unix timestamp; `0` means unset (CRE backfill pending).
    uint256 birthDate;
    /// @dev Argmax of `minsByPosition` (ties keep the existing value).
    Position expectedPosition;
    /// @dev Cumulative minutes per `Position`.
    uint32[POSITION_COUNT] minsByPosition;
}

/// @notice Single-match appearance delta to accumulate into `MinutesStore`.
struct Appearance {
    bytes32 playerId;
    Position position;
    uint32 minsPlayed;
}

/// @notice CRE report payload for DOB backfill (`abi.encode` of the two arrays).
struct BirthDateReport {
    bytes32[] playerIds;
    uint256[] birthDates;
}

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
