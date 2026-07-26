// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Position } from "@types/PlayerSetTypes.sol";

// --------------------------------------------
//  Squad-Fill Workflow
// --------------------------------------------

enum RunStatus { IDLE, TRANSIENT, POPULATING, ARTIFACT }

// For recursively working through seasonIds per leagueId
struct RunNumber {
    uint16 runNumber;
    bytes32 leagueId;
    bytes32[] seasonIds;
    uint16[] seasonStartYears;
    RunStatus[] seasonStatuses;
}

// For upserting MinutesStore entries
struct TransientReturn {
    uint16 pageFetched;
    uint16 nextPage;
    bytes32 leagueId;
    bytes32 seasonId;
    uint16 seasonStartYear;
    bytes32[] playerIds;
    bytes32[] clubIds;
    string[] playerNames;
    string[] playerSymbols;
    uint32[] birthDates;
}

// For detecting removals
struct SquadList {
    bytes32 clubId;
    bytes32[] playerIds;
}

// --------------------------------------------
//  Storage
// --------------------------------------------

uint256 constant POSITION_COUNT = 14;

struct MinutesStore {
    bytes32 currentLeagueId;
    bytes32 currentClubId;
    string name;
    string symbol;
    uint32 birthDate;
    Position expectedPosition;
    uint32[POSITION_COUNT] positionMinutes;
    LeagueMinutes[] leagueMinutes;
}

struct LeagueMinutes {
    bytes32 leagueId;
    uint256 weightedScoreWad;
    uint32 lastScoreGlobalRound;
}

// --------------------------------------------
//  PPM-Verify Workflow
// --------------------------------------------

struct Appearance {
    bytes32 leagueId;
    bytes32 playerId;
    Position position;
    uint32 minsPlayed;
}

// --------------------------------------------
//  Score math (fixed)
// --------------------------------------------

/// @dev Fixed-point scale for `weightedScoreWad` / `LAMBDA_WAD`.
uint256 constant SCORE_WAD = 1e18;

/// @dev λ = 0.97 — half-life ≈ ln(0.5)/ln(0.97) ≈ 23 rounds.
uint256 constant LAMBDA_WAD = 97e16;

// --------------------------------------------
//  Eligibility Buckets
// --------------------------------------------

// Defines which threshold a candidate falls into
enum EligibilityTypes {
    None,
    Goalkeeper,
    Under21,
    Outfield,
    NewTransfer
}

// For sending change requests to DopplerLocker/TransferLocker
struct EligibilityGroups {
    bytes32[] goalkeepers;
    bytes32[] under21;
    bytes32[] outfield;
    bytes32[] newTransfers;
    bytes32[] toDeactivate;
    bytes32[] toReactivate;
}