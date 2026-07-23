// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/token/ERC20/extensions/ERC20Permit.sol";

import { VaultsErrors as Errors } from "@base/global/libraries/errors/vaults/VaultsErrors.sol";
import { VaultsEvents as Events } from "@base/global/libraries/events/vaults/VaultsEvents.sol";
import { ERC20Snapshot } from "@base/abstract/ERC20Snapshot.sol";

/**
 * @title StakedToken
 * @notice Soulbound receipt for player-token stakes in a single `PlayerVault`.
 * @dev Transferable only to/from `vault`. Snapshot + mint/burn are vault-gated.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract StakedToken is ERC20, ERC20Snapshot, ERC20Permit {
    /// @notice PlayerVault that solely controls mint/burn/snapshot and is the only transfer counterparty
    address public immutable vault;

    constructor(string memory name_, string memory symbol_, address vault_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        if (vault_ == address(0)) revert Errors.ZeroAddress();
        vault = vault_;
    }

    /// @notice Creates a new balance/supply snapshot. Vault-only.
    function snapshot() external returns (uint256) {
        if (msg.sender != vault) revert Errors.OnlyVault();
        return _snapshot();
    }

    /// @notice Mints staked receipts 1:1 with deposited player tokens. Vault-only.
    function mint(address to, uint256 amount) external {
        if (msg.sender != vault) revert Errors.OnlyVault();
        _mint(to, amount);
    }

    /// @notice Burns staked receipts on unstake. Vault-only.
    function burn(address from, uint256 amount) external {
        if (msg.sender != vault) revert Errors.OnlyVault();
        _burn(from, amount);
    }

    /// @dev Restrict peer-to-peer transfers; mint/burn and vault legs are allowed.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Snapshot) {
        if (from != address(0) && to != address(0)) {
            if (from != vault && to != vault) revert Errors.OnlyVault();
        }
        super._update(from, to, value);
    }
}
