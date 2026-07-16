// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * Daily, when zk proof is verified:
 * - Needs to maintain RoundSchedule for each tournament (startTime/endTime, fixture lists, etc.)
 *     - Make sure that each PBRTreasury references its own corresponding RoundSchedule for
 *       up-to-date values (single source of truth per tournament).
 * 
 * Weekly, when zk proof is verified:
 * - Needs to maintain the vaultRegistry in each PBRTreasury with activity statuses per tournament.
 * - Needs to maintain activeTournaments for each player in PlayerSetRegistry.
 */