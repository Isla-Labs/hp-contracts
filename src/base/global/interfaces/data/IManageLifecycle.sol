// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { LifecycleReason, PendingLifecycle } from "@base/global/types/LifecycleTypes.sol";

/**
 * @title IManageLifecycle
 * @notice Waiting-room intake for deployed players flagged for soft-inactivity.
 * @dev Mirrors `IDeployDoppler` / DeployDoppler waiting room. Actual `INACTIVE` writes
 *      happen later after manual review (Automator path), not at enqueue time.
 */
interface IManageLifecycle {
    /**
     * @notice Queue players for lifecycle review (same `reason` / parallel `effectiveMins`).
     * @dev Called by `EligibilityVerifier` only. Skips zero ids and already-queued players.
     *      `effectiveMins.length` must be 0 (treated as all zeros) or equal `playerIds.length`.
     */
    function enqueueLifecycle(
        bytes32[] calldata playerIds,
        LifecycleReason reason,
        uint32[] calldata effectiveMins
    ) external;

    function pendingCount() external view returns (uint256);

    function isQueued(bytes32 playerId) external view returns (bool);

    function pendingLifecycle(uint256 offset, uint256 limit)
        external
        view
        returns (PendingLifecycle[] memory out);
}
