// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library GovernanceErrors {
    error ExecutionFailed();
    error ZeroAddress();
    error ArrayLengthsMismatch();
    error EmptyVerifiedCallers();
    error AlreadyVerifiedCaller(address caller);
    error NotVerifiedCaller(address caller);
}
