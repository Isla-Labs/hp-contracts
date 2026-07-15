// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

struct Tournament {
    bytes32 leagueId;
    address pbrTreasury;
    Season[] seasons;
}

struct Season {
    uint32 startYear;
    Matchweek[] matchweeks;
    Cup[] domesticCups;
}

struct Matchweek {
    uint32 mwNumber;
    uint256 mwStartTime;
    uint256 mwEndTime;
}

struct Cup {
    bytes32 cupId;
    Round[] rounds;
}

struct Round {
    uint32 roundNumber;
    uint256 roundStartTime;
    uint256 roundEndTime;
}