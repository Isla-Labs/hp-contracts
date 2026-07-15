// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PoolKey } from "@v4-core/types/PoolKey.sol";

/**
 * @title AssetTypes
 * @notice Onchain market discovery schema for `AssetRegistry`.
 * @dev `playerId` is the registry primary key and is not stored inside these structs.
 */

struct ActiveTournament {
    bytes32 leagueId;
    bytes32[] cupIds;
}

/// @notice Core identity + lifecycle timestamps for a registered player market.
struct AssetData {
    bytes32 leagueId;
    address token;
    string symbol;
    MarketStatus marketStatus;
    uint64 deployedAt;
    uint64 graduatedAt;
    uint64 deactivatedAt;
}

enum MarketStatus {
    BONDING,
    GRADUATED,
    DEACTIVATED
}

// --------------------------------------------
//  Independently deployable registry sets
// --------------------------------------------

struct SpotMarketData {
    PoolKey activePool;
    address hookDoppler;
    address hookMigrator;
    address feeRouter;
}

struct AdvancedTradeData {
    address advancedTradeVault;
    address markSource;
}

struct PlayerVaultData {
    address playerVault;
    address stToken;
    bool isUtilized;
}

// --------------------------------------------
//  DN404 CreateParams
// --------------------------------------------

struct DN404CreateParams {
    bytes32 playerId;
    bytes32 leagueId;
    string name;
    string symbol;
    bytes32 salt;
}
