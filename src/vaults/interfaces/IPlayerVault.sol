// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IPlayerVault
 * @notice Per-market PBR staking vault. Users reallocate manually to AdvancedTrade if desired.
 * @dev Stake ↔ long-escrow exclusivity: the same tokens cannot earn PBR and long funding at once.
 *      There is no calendar auto-lend into short inventory — that path was removed due to
 *      partial-recall / cutoff risk. Inventory expansion remains governance `expandInventory`.
 */
interface IPlayerVault {
    // --------------------------------------------
    //  Events
    // --------------------------------------------

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event AdvancedTradeVaultUpdated(address indexed previous, address indexed next);
    event UtilizedUpdated(bool isUtilized);

    // --------------------------------------------
    //  Errors
    // --------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientStake();
    error EscrowedInAdvancedTrade();
    error NotOwner();

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function playerToken() external view returns (address);
    function stToken() external view returns (address);
    function advancedTradeVault() external view returns (address);
    function isUtilized() external view returns (bool);
    function totalStaked() external view returns (uint256);

    /// @notice Player-token amount staked by `account` (stToken balance). Used by AdvancedTrade exclusivity.
    function stakedBalance(address account) external view returns (uint256);

    // --------------------------------------------
    //  Stake lifecycle
    // --------------------------------------------

    /// @notice Pull `amount` player tokens and mint 1:1 stToken. Reverts if account has AT long escrow.
    function stake(uint256 amount) external;

    /// @notice Burn `amount` stToken and return player tokens.
    function unstake(uint256 amount) external;

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    function setAdvancedTradeVault(address vault) external;
    function setUtilized(bool utilized) external;
}
