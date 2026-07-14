// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IPlayerVaultFactory
 * @notice Deploys per-market PlayerVault + StakedToken pairs for LifecycleTimelock.
 */
interface IPlayerVaultFactory {
    event VaultCreated(address indexed playerToken, address indexed vault, address indexed stToken);

    error ZeroAddress();
    error VaultAlreadyExists();

    function lifecycleTimelock() external view returns (address);
    function vaultOf(address playerToken) external view returns (address);

    /// @notice Deploy PlayerVault for `playerToken` (owner = LifecycleTimelock).
    function create(address playerToken) external returns (address playerVault);
}
