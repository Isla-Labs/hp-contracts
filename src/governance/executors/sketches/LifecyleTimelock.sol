// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * When a player is created:
 * - Need to deploy Doppler market with preconfigured parameters.
 * - Need to deploy FeeRouter and set the leagueId / pbrFeeHub accordingly.
 * - Need to deploy PlayerVault and set the active tournaments.
 * - Need to add PlayerVault address to each PBRTreasury's independent vaultRegistry.
 * - Need to deploy advancedTradeVault and markSource, even though they will be stubs initially.
 * - Need to add PlayerSet to PlayerSetRegistry.
 * 
 * --- Do we need to handle Doppler migration calls in this contract?
 * 
 * When a player moves to a new league:
 * - Needs to update PbrFeeHub address when a player moves to a new league.
 * - Needs to remove the PlayerVault from each PBRTreasury implementation.
 * - Needs to add the PlayerVault to each PBRTreasury for the new league.
 * 
 * When a player is no longer supported:
 * - Need to remove PbrFeeHub address from FeeRouter.
 * - Need to remove the PlayerVault from each PBRTreasury implementation.
 * - Need to set the PlayerVault to inactive and only allow withdrawals.
 */
