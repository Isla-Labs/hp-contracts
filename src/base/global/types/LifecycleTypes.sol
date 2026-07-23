// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @notice Why a deployed player was queued for soft-inactivity review.
 * @dev Continuity = under GK/u21/outfield threshold in `verifyEligibility`.
 *      LeftLeague = no club after a full daily-active squad-fill sweep.
 */
enum LifecycleReason {
    ContinuityUnderThreshold,
    LeftLeague
}

/**
 * @notice One ManageLifecycle waiting-room entry (manual review before INACTIVE).
 * @dev Mirrors `DopplerTypes.PendingEligible` for the inactivity path.
 */
struct PendingLifecycle {
    bytes32 playerId;
    LifecycleReason reason;
    /// @dev Effective weighted minutes at enqueue time (0 for LeftLeague / unknown).
    uint32 effectiveMins;
}
