// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library MigrationEvents {
    /// @notice CVM bonding scan opened.
    event MigrationScanRequested(bytes32 indexed requestId);

    /// @notice CVM scan fulfilled (or erred); `tokenCount` is decoded candidate length.
    event MigrationScanFulfilled(bytes32 indexed requestId, uint256 tokenCount, bytes err);

    /// @notice Player market synced to GRADUATED with migrated spot pool.
    event MigrationSynced(bytes32 indexed playerId, address indexed token, address hooks);

    /// @notice Token skipped (unknown, not BONDING, not exited, migrate race, etc.).
    event MigrationSkipped(address indexed token, bytes reason);
}
