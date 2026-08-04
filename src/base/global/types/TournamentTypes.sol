// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Competition class used by fee routing (`PbrFeeHub`) and calendars.
/// @dev Domestic leagues own a fee hub; domestic cups share that hub as destinations.
enum TournamentType {
    DOMESTIC_LEAGUE,
    DOMESTIC_CUP,
    CONTINENTAL,
    INTERNATIONAL
}

struct Tournament {
    TournamentType tournamentType;
    Hub[] feeHubs; // list of PbrFeeHub contracts that distribute fees to this tournament
    bytes32 tournamentId;
    address pbrTreasury;
    Season[] seasons; // identity stubs; round calendar SoT is `RoundManager`
}

struct Hub {
    bytes32 leagueId;
    address pbrFeeHub;
}

// --------------------------------------------
//  Season identity per tournament (TournamentRegistry)
// --------------------------------------------

/// @notice Season identity only — `finalRound` / rounds live in `RoundManager`.
struct Season {
    bytes32 seasonId;
    uint16 seasonStartYear;
}

// --------------------------------------------
//  Round calendar (RoundManager)
// --------------------------------------------

struct RoundSchedule {
    uint32 roundNumber;
    uint64 startTime;
    uint64 endTime;
    bytes32[] fixtureIds;
}
