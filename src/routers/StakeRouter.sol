// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { RoutersErrors as Errors } from "@errors/routers/RoutersErrors.sol";
import { RoutersEvents as Events } from "@events/routers/RoutersEvents.sol";
import { VaultData } from "@types/registries/PlayerSetTypes.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { IPlayerVault } from "@interfaces/vaults/IPlayerVault.sol";

/**
 * @title StakeRouter
 * @notice PSR lookup + thin forwarder for `PlayerVault` stake / unstake / claim.
 * @dev Users approve the target vault for `playerToken` (not this router). Soulbound stTokens are
 *      minted/burned to/from `msg.sender` via vault `*For` entrypoints gated to this contract.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract StakeRouter is AddressBook, ReentrancyGuard {
    IPlayerSetRegistry public immutable playerSetRegistry;

    constructor(address addressProvider_) AddressBook(addressProvider_) {
        playerSetRegistry = IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));
    }

    // --------------------------------------------
    //  User entrypoints
    // --------------------------------------------

    /// @notice Stake `amount` of `token` into its PlayerVault on behalf of `msg.sender`.
    function stake(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert Errors.ZeroAmount();
        address vault = _vaultOf(token);
        IPlayerVault(vault).stakeFor(msg.sender, amount);
        emit Events.Staked(msg.sender, token, vault, amount);
    }

    /// @notice Unstake `amount` from the vault for `token` on behalf of `msg.sender`.
    function unstake(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert Errors.ZeroAmount();
        address vault = _vaultOf(token);
        IPlayerVault(vault).unstakeFor(msg.sender, amount);
        emit Events.Unstaked(msg.sender, token, vault, amount);
    }

    /// @notice Claim PBR for `msg.sender` from the vault for `token`.
    function claim(address token) external nonReentrant returns (uint256 payout) {
        address vault = _vaultOf(token);
        payout = IPlayerVault(vault).claimFor(msg.sender);
        emit Events.Claimed(msg.sender, token, vault, payout);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @notice Resolve PlayerVault for a player token (reverts if unknown / mismatched).
    function vaultOf(address token) external view returns (address) {
        return _vaultOf(token);
    }

    // --------------------------------------------
    //  Internal
    // --------------------------------------------

    function _vaultOf(address token) internal view returns (address vault) {
        if (token == address(0)) revert Errors.ZeroAddress();

        bytes32 playerId = playerSetRegistry.playerIdOfToken(token);
        if (playerId == bytes32(0)) revert Errors.UnknownToken(token);

        VaultData memory vaultData = playerSetRegistry.getVaultData(playerId);
        vault = vaultData.playerVault;
        if (vault == address(0)) revert Errors.UnknownVault(token);

        address vaultToken = IPlayerVault(vault).playerToken();
        if (vaultToken != token) revert Errors.TokenVaultMismatch(token, vaultToken);
    }
}
