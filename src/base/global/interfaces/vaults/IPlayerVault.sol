// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IPlayerVault
 * @notice Minimal vault surface used by treasuries / registries / StakeRouter.
 */
interface IPlayerVault {
    function playerId() external view returns (bytes32);

    function playerToken() external view returns (address);

    function stToken() external view returns (address);

    function totalStaked() external view returns (uint256);

    /// @notice Mirror tournament treasury membership (TournamentRegistry only).
    function syncActiveTreasury(bytes32 tournamentId, address treasury, bool active) external;

    /// @notice Soft-pause / restore staking (PlayerSetRegistry lifecycle only).
    function setActive(bool active_) external;

    function activeTreasuryCount() external view returns (uint256);

    function activeTreasuryAt(uint256 index) external view returns (bytes32 tournamentId_, address treasury);

    /// @notice StakeRouter-only: pull `playerToken` from `user`, mint stToken to `user`.
    function stakeFor(address user, uint256 amount) external;

    /// @notice StakeRouter-only: burn `user` stToken and return `playerToken` to `user`.
    function unstakeFor(address user, uint256 amount) external;

    /// @notice StakeRouter-only: claim PBR for `user` (ETH paid to `user`).
    function claimFor(address user) external returns (uint256);
}
