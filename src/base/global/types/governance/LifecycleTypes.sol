// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @notice Why a deployed player was queued for lifecycle review.
 * @dev Continuity = under GK/u21/outfield threshold → soft-inactive review.
 *      LeftLeague = no club after a full daily-active squad-fill sweep.
 *      Reactivate = already `INACTIVE`, now back above continuity threshold.
 */
enum LifecycleReason {
    ContinuityUnderThreshold,
    LeftLeague,
    Reactivate
}

/**
 * @notice One TransferLocker waiting-room entry (manual review before status change).
 * @dev Mirrors DopplerLocker pending intake for deactivate / reactivate paths.
 */
struct PendingLifecycle {
    bytes32 playerId;
    LifecycleReason reason;
    /// @dev Effective weighted minutes at enqueue time (0 for LeftLeague / unknown).
    uint32 effectiveMins;
}
