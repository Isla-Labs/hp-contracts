// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DelayedBatchExecutor } from "@governance/core/DelayedBatchExecutor.sol";

/**
 * @title ActivityExecutor
 * @notice Matchweek calendars + per-player active tournament upkeep.
 * @dev Holds `ACTIVITY_ROLE` on `PlayerSetRegistry` and writers on MatchweekManager /
 *      MatchweekRegistry (when live).
 *
 *      Decision class: **Class 1** target — squad / fixture attestations via `executeWithProof`.
 *      Transitional: short-delay `schedule` from a keeper granted `PROPOSER_ROLE` by the DAO.
 *
 *      Cadence:
 *      - **Daily:** MatchweekManager start/end, fixture lists → MatchweekRegistry
 *        (single source of truth per tournament for PBRTreasury)
 *      - **Weekly:** vault activity status per tournament on PlayerSetRegistry /
 *        PBRTreasury vaultRegistry
 *
 *      Fixture *amendments* after publish but before mwEndTime remain Class 2 (Multisig),
 *      per trustlessPpm governance surface.
 *
 *      Entry points inherited: `schedule`, `execute`, `executeWithProof`, `cancel`.
 */
contract ActivityExecutor is DelayedBatchExecutor {
    /// @notice Short delay; proof path should be preferred once verifier is set
    uint256 public constant DEFAULT_MIN_DELAY = 1 hours;

    constructor(address admin_) DelayedBatchExecutor(admin_, DEFAULT_MIN_DELAY) {}
}
