// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { LifecycleReason } from "@types/lockers/LifecycleTypes.sol";

library LifecycleEvents {
    /// @notice Enqueue writer (`EligibilityVerifier`).
    event EligibilityVerifierSet(address indexed eligibilityVerifier);

    /// @notice Waiting-room intake (`added` new ids this call).
    event LifecyclePlayersEnqueued(LifecycleReason reason, uint256 added, uint256 pendingTotal);
}
