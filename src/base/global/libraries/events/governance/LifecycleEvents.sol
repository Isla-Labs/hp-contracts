// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { LifecycleReason } from "@types/governance/LifecycleTypes.sol";

library LifecycleEvents {
    /// @notice Sole writer for `enqueueLifecycle` (`Automator`).
    event AutomatorSet(address indexed automator);

    /// @notice Waiting-room intake via Automator (`added` new ids this call).
    event LifecyclePlayersEnqueued(LifecycleReason reason, uint256 added, uint256 pendingTotal);
}
