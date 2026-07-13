// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

struct LeagueData {
    bytes32 leagueId;
    address pbrTreasury;
    Season[] seasons;
    MatchweekInfo matchweekInfo;
}

// --------------------------------------------
//  Season Info
// --------------------------------------------

struct Season {
    uint256 calendarId;
    CupCompetition[] cupCompetitions;
    uint256 unixStartTime;
    uint256 unixEndTime;
}

struct CupCompetition {
    bytes32 cupCompetitionId;
    ActiveMatchweek activeRound;
    uint16 totalRounds;
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
}
