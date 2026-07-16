// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IPlayerVault
 * @notice Minimal vault surface used by `PbrTreasury` during round lock.
 */
interface IPlayerVault {
    function playerId() external view returns (bytes32);

    function stToken() external view returns (address);

    /// @notice Snapshot id for a cup season round (0 if not yet snapshotted)
    function snapIdOf(bytes32 cupId, uint16 seasonId, uint32 roundNumber) external view returns (uint256);

    /// @notice Snapshot staked balances for `(cupId, seasonId, roundNumber)` at mwStartTime
    function snapshot(bytes32 cupId, uint16 seasonId, uint32 roundNumber) external returns (uint256 snapId);
}
