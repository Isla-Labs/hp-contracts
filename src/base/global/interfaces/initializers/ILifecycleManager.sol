// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { LifecycleReason, PendingLifecycle } from "@types/initializers/LifecycleTypes.sol";

/**
 * @title ILifecycleManager
 * @notice Waiting-room intake for deactivate / reactivate / cross-league transfer.
 * @dev Replaces `TransferLocker`. Enqueue / unqueue / process are Orchestrator-only; the public
 *      entry is `Orchestrator.enqueueLifecycle` (deployer) and `Orchestrator.processLifecycle`.
 *      Registry writes go to `PlayerSetRegistry` directly (no Orchestrator.execute relay).
 */
interface ILifecycleManager {
    /**
     * @notice Queue players for lifecycle review (same `reason` / parallel `effectiveMins`).
     * @dev Orchestrator-only. Skips zero ids and already-queued players for that direction
     *      (deactivate vs reactivate). `effectiveMins.length` must be 0 (all zeros) or equal
     *      `playerIds.length`.
     */
    function queueChanges(
        bytes32[] calldata playerIds,
        LifecycleReason reason,
        uint32[] calldata effectiveMins
    ) external;

    /// @notice Manual override during the review window (`Queued` only). Orchestrator-only.
    function unqueueAsset(bytes32 playerId) external;

    /**
     * @notice Finalize the next mature `Queued` entry. Orchestrator-only (rate-limit on Orchestrator).
     * @dev Continuity / LeftLeague → `INACTIVE`.
     *      ChangedLeague / Reactivate → `CvmJob.LeagueTransfer` → fulfill → `setLeagueId`
     *      (+ Reactivate: `reactivate()`).
     */
    function processLifecycle() external returns (bytes32 requestId);

    function setQueueWait(uint256 queueWait_) external;

    function pendingCount() external view returns (uint256);

    function isQueued(bytes32 playerId) external view returns (bool);

    function isQueuedFor(bytes32 playerId, LifecycleReason reason) external view returns (bool);

    function pendingLifecycle(uint256 offset, uint256 limit) external view returns (PendingLifecycle[] memory out);

    /**
     * @notice Reverts unless `leagueId → FeeRouter.pbrFeeHub` matches (when league is set).
     * @dev Does not require live vault registration (claims use snapshot-era points).
     */
    function requireFeeTopologyConsistent(bytes32 playerId) external view;
}
