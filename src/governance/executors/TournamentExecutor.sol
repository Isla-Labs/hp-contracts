// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DelayedBatchExecutor } from "@governance/core/DelayedBatchExecutor.sol";

/**
 * @title TournamentExecutor
 * @notice League / cup topology deployment (Class 2 — product ops, not ZK).
 * @dev Holds `DEPLOYER_ROLE` on `TournamentRegistry`. Creates hubs, treasuries, matchweek managers.
 *
 *      Remains Multisig-gated at launch (which competitions to list is a product decision).
 *      Optional later: calendar proofs vs attested fixture sets.
 *
 *      Bundles:
 *
 *      **League created**
 *      - Deploy PbrFeeHub
 *      - Deploy PbrTreasury
 *      - Deploy MatchweekManager
 *      - TournamentRegistry.registerHub / createTournament / openSeason
 *
 *      **Cup added**
 *      - Deploy PbrTreasury; wire into PbrFeeHub for leagueId + type
 *      - Deploy MatchweekManager
 *      - Update eligible PlayerVaults on the cup treasury
 *
 *      Entry points inherited: `schedule`, `execute`, `cancel`.
 *      Proof path unused unless a calendar verifier is later attached.
 */
contract TournamentExecutor is DelayedBatchExecutor {
    uint256 public constant DEFAULT_MIN_DELAY = 2 days;

    constructor(address admin_) DelayedBatchExecutor(admin_, DEFAULT_MIN_DELAY) {}
}
