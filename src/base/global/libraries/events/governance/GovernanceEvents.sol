// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library GovernanceEvents {
    event AutomationExecuted(address indexed target, uint256 value, bytes data, bytes result);
    event VerifiedCallerAdded(address indexed caller);
    event VerifiedCallerRemoved(address indexed caller);
    event VerifiedDestinationAdded(address indexed caller, address indexed target);
    event VerifiedDestinationRemoved(address indexed caller, address indexed target);
    event AfterDelayExecuted(address indexed target, uint256 value, bytes data, bytes result);
    event ConstitutionalExecuted(address indexed target, uint256 value, bytes data, bytes result);
}
