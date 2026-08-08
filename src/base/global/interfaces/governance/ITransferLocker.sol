// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { LifecycleReason, PendingLifecycle } from "@types/lockers/LifecycleTypes.sol";

/**
 * @title ITransferLocker
 * @notice Waiting-room intake for deployed players flagged for deactivate / reactivate.
 * @dev Mirrors DopplerLocker waiting room. Actual status writes happen later after
 *      manual review (Orchestrator path), not at enqueue time.
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

    function pendingCount() external view returns (uint256);

    /// @notice True if queued for deactivate and/or reactivate.
    function isQueued(bytes32 playerId) external view returns (bool);

    /// @notice True if queued for the given reason's direction.
    function isQueuedFor(bytes32 playerId, LifecycleReason reason) external view returns (bool);

    function pendingLifecycle(uint256 offset, uint256 limit) external view returns (PendingLifecycle[] memory out);

    /**
     * @notice Reverts unless `leagueId → FeeRouter.pbrFeeHub / PbrTreasury` topology matches.
     * @dev Used by `confirmReactivate` and offchain scanners before cross-league / continuity restore.
     */
    function requireFeeTopologyConsistent(bytes32 playerId) external view;
}
