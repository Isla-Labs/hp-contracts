// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { PoolKey } from "@v4-core/types/PoolKey.sol";

struct AssetData {
    bytes32 playerId;
    bytes32 leagueId;
    address token;
    string symbol;
    RegistryData registryData;
    MarketStatus marketStatus;
}

struct RegistryData {
    SpotMarketData spotMarketData;
    AdvancedTradeData advancedTradeData;
    PlayerVaultData playerVaultData;
    uint256 deployedAt;
    uint256 graduatedAt;
    uint256 deactivatedAt;
}

enum MarketStatus {
    BONDING,
    GRADUATED,
    DEACTIVATED
}

// --------------------------------------------
//  Registry Data
// --------------------------------------------

struct SpotMarketData {
    PoolKey activePool;
    address hookDoppler;
    address hookMigrator;
    address feeRouter;
}

struct AdvancedTradeData {
    address advancedTradeVault;
    address upToken; // double-check whether this is necessary
    address dwnToken; // double-check whether this is necessary
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
