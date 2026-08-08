// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IPlayerVault
 * @notice Minimal vault surface used by `PbrTreasury` during round lock / settle.
 */
interface IPlayerVault {
    function playerId() external view returns (bytes32);

    function stToken() external view returns (address);

    /// @notice Live staked inventory; `> 0` means utilized for matchweek snapshot membership.
    function totalStaked() external view returns (uint256);

    /// @notice Snapshot id for a tournament season round (0 if not yet snapshotted)
    function snapIdOf(bytes32 tournamentId, uint16 seasonId, uint32 roundNumber) external view returns (uint256);

    /**
     * @notice Snapshot staked balances for `(tournamentId, seasonId, roundNumber)`.
     * @dev Callable only by `TournamentRegistry.getPbrTreasury(tournamentId)`.
     *      Returns `(0, false)` when unutilized; idempotent if already snapshotted.
     */
    function snapshot(bytes32 tournamentId, uint16 seasonId, uint32 roundNumber)
        external
        returns (uint256 snapId, bool didSnap);
}
