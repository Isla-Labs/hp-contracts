// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { 
    DN404CreateParams,
    SpotMarketData,
    AdvancedTradeData,
    PlayerVaultData
} from "@base/global/types/AssetTypes.sol";

/**
 * When a player is created:
 * - Need to deploy Doppler market with preconfigured parameters.
 * - Need to deploy FeeRouter and set the leagueId / pbrFeeHub accordingly.
 * - Need to deploy PlayerVault and set the active tournaments.
 * - Need to add PlayerVault address to each PBRTreasury's independent vaultRegistry.
 * 
 * When a player moves to a new league:
 * - Needs to update PbrFeeHub address when a player moves to a new league.
 * - Needs to remove the PlayerVault from each PBRTreasury implementation.
 * - Needs to add the PlayerVault to each PBRTreasury for the new league.
 */