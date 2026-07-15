// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

struct Tournament {
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
    uint64 mwStartTime;
    uint64 mwEndTime;
}

struct Cup {
    bytes32 cupId;
    Round[] rounds;
}

struct Round {
    uint32 roundNumber;
    uint64 roundStartTime;
    uint64 roundEndTime;
}