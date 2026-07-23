// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library LifecycleErrors {
    error ZeroAddress();
    error Unauthorized();
    error AlreadySet();
    error LengthMismatch(uint256 left, uint256 right);
}
