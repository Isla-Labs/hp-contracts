// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

/**
 * @title StakedToken
 * @notice 1:1 receipt for player tokens locked in a PlayerVault (non-transferable wireframe optional later).
 * @dev Only the bound PlayerVault may mint/burn. Transfers are enabled for wireframe UX; PBR
 *      snapshots should read `PlayerVault.stakedBalance` (vault custody), not free-floating stToken
 *      once transfer restrictions land.
 */
contract StakedToken is ERC20 {
    address public immutable vault;

    error NotVault();
    error ZeroAddress();

    constructor(string memory name_, string memory symbol_, address vault_) ERC20(name_, symbol_) {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != vault) revert NotVault();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != vault) revert NotVault();
        _burn(from, amount);
    }
}
