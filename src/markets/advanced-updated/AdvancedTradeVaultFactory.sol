// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { IAdvancedTradeVault } from "./interfaces/IAdvancedTradeVault.sol";
import { IAdvancedTradeVaultFactory } from "./interfaces/IAdvancedTradeVaultFactory.sol";
import {
    INVENTORY_HARD_CAP,
    SEEDED_INVENTORY,
    VaultInitParams
} from "./types/AdvancedTradeTypes.sol";

/**
 * @title AdvancedTradeVaultFactory
 * @notice Deploys per-market AdvancedTradeVault BeaconProxies; owns the shared UpgradeableBeacon.
 * @dev Owner should be LifecycleTimelock. Beacon upgrades = single honeypot (§6.1) — timelock only.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract AdvancedTradeVaultFactory is IAdvancedTradeVaultFactory, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Shared beacon for all market vaults
    UpgradeableBeacon public immutable vaultBeacon;

    /// @notice playerToken → vault
    mapping(address playerToken => address vault) public override vaultOf;

    /**
     * @param initialOwner LifecycleTimelock (or governance).
     * @param implementation_ AdvancedTradeVault implementation logic.
     */
    constructor(address initialOwner, address implementation_) Ownable(initialOwner) {
        if (initialOwner == address(0) || implementation_ == address(0)) revert ZeroAddress();
        // Factory owns the beacon so `setImplementation` is a single entrypoint; factory itself
        // is Ownable2Step-owned by LifecycleTimelock (§6.1 honeypot path).
        vaultBeacon = new UpgradeableBeacon(implementation_, address(this));
    }

    /// @inheritdoc IAdvancedTradeVaultFactory
    function beacon() external view override returns (address) {
        return address(vaultBeacon);
    }

    /// @inheritdoc IAdvancedTradeVaultFactory
    function implementation() external view override returns (address) {
        return vaultBeacon.implementation();
    }

    /// @inheritdoc IAdvancedTradeVaultFactory
    function owner() public view override(IAdvancedTradeVaultFactory, Ownable) returns (address) {
        return Ownable.owner();
    }

    /**
     * @notice Deploy + initialize a vault for `playerToken`, seeding short inventory.
     * @dev Caller (or this factory after pull) must hold `seededInventory` of `playerToken`.
     *      Default seed is SEEDED_INVENTORY (1M); must be ≤ INVENTORY_HARD_CAP (4M).
     */
    function create(
        address playerToken,
        address collateral,
        address swapRouter,
        address fundingController,
        address pbrTreasury,
        uint256 seededInventory
    ) external override onlyOwner nonReentrant returns (address vault) {
        if (playerToken == address(0) || collateral == address(0) || pbrTreasury == address(0)) revert ZeroAddress();
        if (vaultOf[playerToken] != address(0)) revert VaultAlreadyExists();
        if (seededInventory == 0) seededInventory = SEEDED_INVENTORY;
        if (seededInventory > INVENTORY_HARD_CAP) revert InvalidSeedAmount();

        bytes memory initData = abi.encodeCall(
            IAdvancedTradeVault.initialize,
            (
                VaultInitParams({
                    playerToken: playerToken,
                    collateral: collateral,
                    swapRouter: swapRouter,
                    fundingController: fundingController,
                    pbrTreasury: pbrTreasury,
                    owner: owner(),
                    seededInventory: seededInventory
                })
            )
        );

        vault = address(new BeaconProxy(address(vaultBeacon), initData));
        vaultOf[playerToken] = vault;

        // Seed inventory into the vault (mint allocation path: pull from deployer / treasury)
        IERC20(playerToken).safeTransferFrom(msg.sender, vault, seededInventory);

        emit VaultCreated(playerToken, vault, address(vaultBeacon), seededInventory);
    }

    /// @inheritdoc IAdvancedTradeVaultFactory
    function setImplementation(address newImplementation) external override onlyOwner {
        if (newImplementation == address(0)) revert ZeroAddress();
        address previous = vaultBeacon.implementation();
        vaultBeacon.upgradeTo(newImplementation);
        emit ImplementationUpdated(previous, newImplementation);
    }
}
