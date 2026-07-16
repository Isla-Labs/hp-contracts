// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

enum TournamentType {
    DOMESTIC,
    CONTINENTAL,
    INTERNATIONAL
}

struct Tournament {
    TournamentType tournamentType;
    Hub[] feeHubs; // list of PbrFeeHub contracts that distribute fees to this tournament
    bytes32 tournamentId;
    address pbrTreasury;
    Season[] seasons;
}

struct Hub {
    bytes32 leagueId;
    address pbrFeeHub;
}

// --------------------------------------------
//  Season calendar per tournament
// --------------------------------------------

struct Season {
    uint16 seasonStartYear;
    uint32 finalRound;
    uint32 roundCount;
    RoundSchedule[] rounds;
}

struct RoundSchedule {
    uint32 roundNumber;
    uint64 startTime;
    uint64 endTime;
    bytes32[] fixtureIds;
}