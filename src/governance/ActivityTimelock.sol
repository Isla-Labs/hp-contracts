// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * Daily:
 * - Needs to maintain MatchweekManager for each tournament (startTime/endTime, fixture lists, etc.)
 *     - Make sure that each PBRTreasury references its own corresponding MatchweekManager for
 *       up-to-date values (single source of truth per tournament).
 * 
 * Weekly:
 * - Needs to maintain the vaultRegistry in each PBRTreasury with activity statuses.
 */
