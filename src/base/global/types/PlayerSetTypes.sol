// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PoolKey } from "@v4-core/types/PoolKey.sol";

enum PlayerStatus {
    BONDING,
    GRADUATED,
    INACTIVE
}

struct PlayerSet {
    PlayerStatus status;
    TokenData tokenData;
    TournamentData tournamentData;
    DopplerData dopplerData;
    VaultData vaultData;
    AdvancedTradeData advancedTradeData;
}

// --------------------------------------------
//  Independently deployable registry sets
// --------------------------------------------

struct TokenData {
    address token;
    string name;
    string symbol;
}

struct PositionData {
    Position expectedPosition;
    PositionMins positionMins;
}

struct TournamentData {
    bytes32 leagueId;
    bytes32[] activeTournaments;
}

struct DopplerData {
    PoolKey activePool;
    address hookDoppler;
    address hookMigrator;
    address feeRouter;
}

struct VaultData {
    address playerVault;
    address stToken;
    bool isUtilized;
}

struct AdvancedTradeData {
    address advancedTradeVault;
    address markSource;
}

// --------------------------------------------
//  Position data
// --------------------------------------------

enum Position {
    GK,
    RB,
    LB,
    CB,
    DM,
    CM,
    CAM,
    RAM,
    LAM,
    RM,
    LM,
    RW,
    LW,
    ST
}

struct PositionMins {
    Position position;
    uint8 minsPlayed;
}
