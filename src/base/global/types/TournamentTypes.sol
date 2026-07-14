// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/**
 * @title TournamentTypes
 * @notice Onchain league / season / matchweek schema for `TournamentRegistry`.
 */

struct LeagueData {
    bytes32 leagueId;
    address pbrTreasury;
    Season[] seasons;
    MatchweekInfo matchweekInfo;
}

// --------------------------------------------
//  Matchweek Info
// --------------------------------------------

struct MatchweekInfo {
    ActiveMatchweek activeMatchweek;
    uint16 tradingMatchweek;
    uint16 totalMatchweeks;
}

struct ActiveMatchweek {
    uint16 activeMatchweek;
    uint256 unixStartTime;
    uint256 unixEndTime;
    /// @notice Fixture set published at matchweek start (`trustlessPpm.md` MatchweekRegistry).
    bytes32[] fixtureUuids;
}

// --------------------------------------------
//  Season Info
// --------------------------------------------

struct Season {
    bytes32 seasonId;
    Round[] matchweeks;
    CupCompetition[] cupCompetitions;
    uint256 seasonStartTime;
    uint256 seasonEndTime;
}

struct Round {
    uint16 round;
    Fixture[] fixtures;
    uint256 roundStartTime;
    uint256 roundEndTime;
}

struct CupCompetition {
    bytes32 cupCompetitionId;
    Round[] rounds;
    uint16 activeRound;
    uint256 activeRoundStartTime;
    uint256 activeRoundEndTime;
}

struct Fixture {
    uint256 fixtureId;
    uint256 unixStartTime;
}
