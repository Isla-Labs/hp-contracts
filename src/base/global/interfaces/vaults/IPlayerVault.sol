// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IPlayerVault
 * @notice Minimal vault surface used by treasuries / registries.
 */
interface IPlayerVault {
    function playerId() external view returns (bytes32);

    function stToken() external view returns (address);

    function totalStaked() external view returns (uint256);

    /// @notice Mirror tournament treasury membership (TournamentRegistry only).
    function syncActiveTreasury(bytes32 tournamentId, address treasury, bool active) external;

    /// @notice Record a round this vault is utilized in (for claimAll / lock tracking).
    function noteUtilizedRound(bytes32 tournamentId, uint16 seasonStartYear, uint32 roundNumber) external;
}
