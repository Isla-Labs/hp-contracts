// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * Deployments:
 * - Check deployment request against eligibility criteria.
 * - If eligible, deploy the squad.
 * - If not eligible, reject the deployment.
 */

/**
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