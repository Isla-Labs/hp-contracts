// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { LifecycleReason, PendingLifecycle } from "@types/lockers/LifecycleTypes.sol";

/**
 * @title ITransferLocker
 * @notice Waiting-room intake for deployed players flagged for deactivate / reactivate / transfer.
 * @dev Mirrors DopplerLocker: enqueue → 24h review → permissionless `processLifecycle`.
 *      Status / league writes go through `PlayerSetRegistry` (SoT) via Orchestrator.
 */
interface ITransferLocker {
    /**
     * @notice Queue players for lifecycle review (same `reason` / parallel `effectiveMins`).
     * @dev Called by `EligibilityVerifier` or Orchestrator owner.
     *      Skips zero ids and already-queued players for that direction (deactivate vs reactivate).
     *      `effectiveMins.length` must be 0 (treated as all zeros) or equal `playerIds.length`.
     */
    function enqueueLifecycle(
        bytes32[] calldata playerIds,
        LifecycleReason reason,
        uint32[] calldata effectiveMins
    ) external;

    /// @notice Owner manual override during the review window (`Queued` only).
    function unqueueAsset(bytes32 playerId) external;

    /**
     * @notice Finalize the next mature `Queued` entry (anyone; rate-limited).
     * @dev Continuity / LeftLeague → `INACTIVE` (clears league / actives, unregisters vaults).
     *      ChangedLeague / Reactivate → `CvmJob.LeagueTransfer` (apply on fulfill:
     *      `setLeagueId`, then Reactivate also `reactivate()`).
     */
    function processLifecycle() external returns (bytes32 requestId);

    function setQueueWait(uint256 queueWait_) external;

    function pendingCount() external view returns (uint256);

    /// @notice True if queued for deactivate and/or reactivate.
    function isQueued(bytes32 playerId) external view returns (bool);

    /// @notice True if queued for the given reason's direction.
    function isQueuedFor(bytes32 playerId, LifecycleReason reason) external view returns (bool);

    function pendingLifecycle(uint256 offset, uint256 limit) external view returns (PendingLifecycle[] memory out);

    /**
     * @notice Reverts unless `leagueId → FeeRouter.pbrFeeHub` matches (when league is set).
     * @dev Does not require live vault registration (claims use snapshot-era points).
     */
    function requireFeeTopologyConsistent(bytes32 playerId) external view;
}
