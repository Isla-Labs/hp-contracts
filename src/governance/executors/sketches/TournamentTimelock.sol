// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * When a league is created:
 * - Need to deploy PbrFeeHub.
 * - Need to deploy PbrTreasury.
 * - Need to deploy MatchweekManager.
 * 
 * When a cup is added:
 * - Need to deploy PbrTreasury and add it to PbrFeeHub for corresponding leagueId, with its type.
 * - Need to deploy MatchweekManager.
 * - Need to update list of eligible PlayerVaults for the cup, in its own PBRTreasury.
 */
