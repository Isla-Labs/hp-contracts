// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library GovernanceErrors {
    error ExecutionFailed();
    error ZeroAddress();
    error TargetNotAllowed(address target);
    error ArrayLengthsMismatch();
    error EmptyVerifiedCallers();
    error EmptyDestinations();
    error AlreadyVerifiedCaller(address caller);
    error NotVerifiedCaller(address caller);
    error DestinationNotAllowed(address caller, address target);
    error AlreadyVerifiedDestination(address caller, address target);
    error NotVerifiedDestination(address caller, address target);
}
