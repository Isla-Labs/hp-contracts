// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/token/ERC20/extensions/ERC20Permit.sol";

import { VaultsErrors as Errors } from "@errors/vaults/VaultsErrors.sol";
import { VaultsEvents as Events } from "@events/vaults/VaultsEvents.sol";
import { ERC20BlockCheckpoint } from "@base/abstract/ERC20BlockCheckpoint.sol";

/**
 * @title StakedToken
 * @notice Soulbound receipt for player-token stakes in a single `PlayerVault`.
 * @dev Transferable only to/from `vault`. Block checkpoints enable `balanceOfAt` / `totalSupplyAt`
 *      for PBR cut-offs without per-round `snapshot()` calls.
 *      `contractURI` is ERC-7572-style metadata (IPFS JSON with image) for wallets / explorers.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract StakedToken is ERC20, ERC20BlockCheckpoint, ERC20Permit {
    /// @notice PlayerVault that solely controls mint/burn and is the only transfer counterparty
    address public immutable vault;

    /// @dev ERC-7572 contract-level metadata URI (`ipfs://…` JSON).
    string private _contractURI;

    constructor(
        string memory name_,
        string memory symbol_,
        address vault_,
        string memory contractURI_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        if (vault_ == address(0)) revert Errors.ZeroAddress();
        if (bytes(contractURI_).length == 0) revert Errors.EmptyURI();
        vault = vault_;
        _contractURI = contractURI_;
        emit Events.StakedTokenCreated(vault_, address(this), name_, symbol_);
    }

    /// @notice Contract-level metadata URI for wallets / explorers (ERC-7572).
    function contractURI() external view returns (string memory) {
        return _contractURI;
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
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20BlockCheckpoint) {
        if (from != address(0) && to != address(0)) {
            if (from != vault && to != vault) revert Errors.OnlyVault();
        }
        super._update(from, to, value);
    }
}
