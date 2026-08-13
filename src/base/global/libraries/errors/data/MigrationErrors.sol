// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library MigrationErrors {
    error ZeroAddress();
    error Unauthorized();
    error EmptyBatch();
    error BatchTooLarge(uint256 length, uint256 maxLength);
    error NotConfigured();
}
