// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IHPStakeRouter
 * @notice User-facing stake/unstake facade over per-market PlayerVaults.
 */
interface IHPStakeRouter {
    event Staked(address indexed account, address indexed playerToken, address indexed vault, uint256 amount);
    event Unstaked(address indexed account, address indexed playerToken, address indexed vault, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error VaultNotRegistered();

    function registry() external view returns (address);

    /// @notice Pull `amount` player tokens from caller, stake into the registered PlayerVault, return stToken.
    function stake(address playerToken, uint256 amount) external;

    /// @notice Pull `amount` stToken from caller, unstake, return player tokens.
    function unstake(address playerToken, uint256 amount) external;

    /// @notice Resolve PlayerVault for `playerToken` from AssetRegistry.
    function vaultOf(address playerToken) external view returns (address);
}
