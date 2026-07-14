// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IAdvancedTradeVaultFactory
 * @notice Deploys per-market AdvancedTradeVault BeaconProxies and seeds short inventory.
 */
interface IAdvancedTradeVaultFactory {
    event VaultCreated(
        address indexed playerToken, address indexed vault, address indexed beacon, uint256 seededInventory
    );
    event ImplementationUpdated(address indexed previous, address indexed next);
    event BeaconOwnershipTransferred(address indexed previous, address indexed next);

    error ZeroAddress();
    error VaultAlreadyExists();
    error InvalidSeedAmount();
    error SeedTransferFailed();
    error NotOwner();

    function beacon() external view returns (address);
    function implementation() external view returns (address);
    function vaultOf(address playerToken) external view returns (address);
    function owner() external view returns (address);

    /// @notice Deploy vault for `playerToken`, pull `seededInventory` tokens into it, initialize.
    function create(
        address playerToken,
        address collateral,
        address swapRouter,
        address fundingController,
        address pbrTreasury,
        uint256 seededInventory
    ) external returns (address vault);

    function setImplementation(address newImplementation) external;
}
