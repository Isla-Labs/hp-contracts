// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { LifecycleReason } from "@base/global/types/LifecycleTypes.sol";

library LifecycleEvents {
    event EligibilityVerifierSet(address indexed eligibilityVerifier);

    /// @notice Waiting-room intake from EligibilityVerifier (`added` new ids this call).
    event LifecyclePlayersEnqueued(
        LifecycleReason reason, uint256 added, uint256 pendingTotal
    );
}
