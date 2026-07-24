// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library GovernanceErrors {
    error ExecutionFailed();
    error ZeroAddress();
    error ArrayLengthsMismatch();
    error RouteNotAllowed(address caller, address target);
}
