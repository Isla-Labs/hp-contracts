// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IPlayerVaultFactory } from "./interfaces/IPlayerVaultFactory.sol";
import { PlayerVault } from "./PlayerVault.sol";

/**
 * @title PlayerVaultFactory
 * @notice Deploys per-market PlayerVault instances owned by LifecycleTimelock.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerVaultFactory is IPlayerVaultFactory {
    /// @notice Owner set on every deployed PlayerVault
    address public immutable override lifecycleTimelock;

    /// @notice playerToken → vault
    mapping(address playerToken => address vault) public override vaultOf;

    /**
     * @param lifecycleTimelock_ Address passed as `owner` to each PlayerVault.
     */
    constructor(address lifecycleTimelock_) {
        if (lifecycleTimelock_ == address(0)) revert ZeroAddress();
        lifecycleTimelock = lifecycleTimelock_;
    }

    /// @inheritdoc IPlayerVaultFactory
    function create(address playerToken) external override returns (address playerVault) {
        if (playerToken == address(0)) revert ZeroAddress();
        if (vaultOf[playerToken] != address(0)) revert VaultAlreadyExists();

        playerVault = address(new PlayerVault(lifecycleTimelock, playerToken));
        vaultOf[playerToken] = playerVault;

        emit VaultCreated(playerToken, playerVault, PlayerVault(playerVault).stToken());
    }
}
