// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @notice Why a deployed player was queued for lifecycle review.
 * @dev Continuity = under GK/u21/outfield threshold → soft-inactive review.
 *      LeftLeague = no club after a season squad snapshot (exit / relegation).
 *      ChangedLeague = still active, cross-league membership move (migrate topology).
 *      Reactivate = already `INACTIVE`, now back above continuity threshold.
 *      Uses the same `LeagueTransfer` oracle as ChangedLeague to restore
 *      `leagueId` / `activeTournaments` (cleared on deactivate) before `setStatus`.
 */
enum LifecycleReason {
    ContinuityUnderThreshold,
    LeftLeague,
    ChangedLeague,
    Reactivate
}

/// @notice TransferLocker waiting-room phase for one pending entry.
enum LifecycleQueueStatus {
    None,
    /// @dev In the review window (`queuedAt + queueWait`).
    Queued,
    /// @dev `CvmJob.LeagueTransfer` in flight (ChangedLeague only).
    AwaitingLeagueTransfer
}

/**
 * @notice One TransferLocker waiting-room entry.
 * @dev Mirrors DopplerLocker pending intake for deactivate / reactivate / transfer paths.
 */
struct PendingLifecycle {
    bytes32 playerId;
    LifecycleReason reason;
    /// @dev Effective weighted minutes at enqueue time (0 for LeftLeague / unknown).
    uint32 effectiveMins;
    uint64 queuedAt;
    LifecycleQueueStatus status;
}
