// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library GovernanceEvents {
    event AutomationExecuted(address indexed target, uint256 value, bytes data, bytes result);
    /// @notice Caller→target route edge updated on Automator (`allowedRoute` matrix).
    event AutomationRouteUpdated(address indexed caller, address indexed target, bool allowed);
    event AfterDelayExecuted(address indexed target, uint256 value, bytes data, bytes result);
    event ConstitutionalExecuted(address indexed target, uint256 value, bytes data, bytes result);
}
