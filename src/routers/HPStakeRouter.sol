// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";

import { AssetRegistry } from "../AssetRegistry.sol";
import { AssetData } from "../base/global/types/AssetTypes.sol";
import { IAdvancedTradeVault } from "../markets/advanced-updated/interfaces/IAdvancedTradeVault.sol";
import { IPlayerVault } from "../vaults/interfaces/IPlayerVault.sol";
import { IHPStakeRouter } from "./interfaces/IHPStakeRouter.sol";

/**
 * @title HPStakeRouter
 * @notice Thin entrypoint for stake/unstake against registry-wired PlayerVaults.
 * @dev Pulls assets from the user, calls the vault (so msg.sender inside the vault is this
 *      router), then forwards stToken / player tokens back to the user. Enforces the same
 *      stake ↔ long-escrow exclusivity gate against the *user* (vault would only see this
 *      router as msg.sender).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract HPStakeRouter is IHPStakeRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    AssetRegistry private immutable _registry;

    constructor(AssetRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        _registry = registry_;
    }

    /// @inheritdoc IHPStakeRouter
    function registry() external view override returns (address) {
        return address(_registry);
    }

    /// @inheritdoc IHPStakeRouter
    function vaultOf(address playerToken) public view override returns (address vault) {
        AssetData memory data = _registry.getAssetData(playerToken);
        vault = data.registryData.playerVaultData.playerVault;
        if (vault == address(0) || data.token != playerToken) revert VaultNotRegistered();
    }

    /// @inheritdoc IHPStakeRouter
    function stake(address playerToken, uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IPlayerVault vault = IPlayerVault(vaultOf(playerToken));
        _requireNotEscrowed(vault, msg.sender);

        IERC20(playerToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(playerToken).forceApprove(address(vault), amount);
        vault.stake(amount);
        IERC20(playerToken).forceApprove(address(vault), 0);

        address st = vault.stToken();
        IERC20(st).safeTransfer(msg.sender, amount);

        emit Staked(msg.sender, playerToken, address(vault), amount);
    }

    /// @inheritdoc IHPStakeRouter
    function unstake(address playerToken, uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IPlayerVault vault = IPlayerVault(vaultOf(playerToken));
        address st = vault.stToken();

        IERC20(st).safeTransferFrom(msg.sender, address(this), amount);
        vault.unstake(amount);
        IERC20(playerToken).safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, playerToken, address(vault), amount);
    }

    function _requireNotEscrowed(IPlayerVault vault, address account) internal view {
        address at = vault.advancedTradeVault();
        if (at == address(0)) return;
        if (IAdvancedTradeVault(at).accountLongSize(account) > 0) {
            revert IPlayerVault.EscrowedInAdvancedTrade();
        }
    }
}
