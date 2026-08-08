// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { LifecycleReason } from "@types/lockers/LifecycleTypes.sol";
import { PlayerStatus } from "@types/registries/PlayerSetTypes.sol";

library LifecycleEvents {
    /// @notice Enqueue writer (`EligibilityVerifier`).
    event EligibilityVerifierSet(address indexed eligibilityVerifier);

    /// @notice Waiting-room intake (`added` new ids this call).
    event LifecyclePlayersEnqueued(LifecycleReason reason, uint256 added, uint256 pendingTotal);

    event AssetUnqueued(bytes32 indexed playerId);

    event QueueWaitUpdated(uint256 previous, uint256 queueWait);

    event LifecycleApplied(bytes32 indexed playerId, LifecycleReason reason, PlayerStatus status);

    event LeagueTransferRequested(bytes32 indexed requestId, bytes32 indexed playerId);

    event LeagueTransferFulfilled(bytes32 indexed requestId, bytes32 indexed playerId, bytes err);
}
