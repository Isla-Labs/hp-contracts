// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title EligibilityTypes
 * @notice Classify / verify outcomes for `EligibilityVerifier`.
 */

/// @notice Per-player outcome after score sync (page classify).
enum VerifyAction {
    None,
    DeployGoalkeeper,
    DeployUnder21,
    DeployOutfield,
    DeployNewTransfer,
    Deactivate,
    Reactivate
}
