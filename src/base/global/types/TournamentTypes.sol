// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title TournamentTypes
 * @notice Competition topology + season-keyed round schedules.
 * @dev Fee path: FeeRouter → `pbrFeeHub` → per-cup `PbrTreasury`.
 *      Calendars / fixtures are per `(cupId, seasonId)` on `TournamentRegistry`.
 */

// --------------------------------------------
//  Competition topology
// --------------------------------------------

struct League {
    /// @notice Fee splitter that `FeeRouter` targets for this league
    address pbrFeeHub;
    bytes32[] cupIds;
}

struct Continental {
    address pbrFeeHub;
    bytes32[] cupIds;
}

struct International {
    address pbrFeeHub;
    bytes32[] cupIds;
}

// --------------------------------------------
//  Season calendar
// --------------------------------------------

/**
 * @notice One round inside a cup season.
 * @dev Unpublished / not lockable while `startTime == 0` or `endTime == 0` or `fixtureIds` empty.
 */
struct RoundSchedule {
    uint32 roundNumber;
    uint64 startTime;
    uint64 endTime;
    bytes32[] fixtureIds;
}

/**
 * @param finalRound Highest round number for this season (wrap trigger). 0 = season not opened.
 * @param roundCount Number of round entries written so far.
 */
struct CupSeasonMeta {
    uint32 finalRound;
    uint32 roundCount;
}
