// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import { VaultsErrors as Errors } from "@base/global/libraries/errors/VaultsErrors.sol";
import { VaultsEvents as Events } from "@base/global/libraries/events/VaultsEvents.sol";
import { PlayerVault } from "@vaults/PlayerVault.sol";
import { StakedToken } from "@vaults/StakedToken.sol";

/**
 * @title PlayerVaultFactory
 * @notice Deploys per-market `PlayerVault` beacon proxies + bound `StakedToken`s.
 * @dev Beacon ownership (logic upgrades) is assigned to `ConstitutionalTimelock`.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerVaultFactory {
    UpgradeableBeacon public immutable beacon;

    /// @notice Granted `CATEGORY_THREE` on each vault
    address public immutable automator;

    /// @notice Granted `CATEGORY_TWO` on each vault
    address public immutable maintenanceTimelock;

    /// @notice Granted `DEFAULT_ADMIN_ROLE` on each vault (pause)
    address public immutable dao;

    /// @notice Owns the beacon (logic upgrades)
    address public immutable constitutionalTimelock;

    address public immutable tournamentRegistry;

    constructor(
        address automator_,
        address maintenanceTimelock_,
        address dao_,
        address constitutionalTimelock_,
        address tournamentRegistry_
    ) {
        if (
            automator_ == address(0) || maintenanceTimelock_ == address(0) || dao_ == address(0)
                || constitutionalTimelock_ == address(0) || tournamentRegistry_ == address(0)
        ) revert Errors.ZeroAddress();

        automator = automator_;
        maintenanceTimelock = maintenanceTimelock_;
        dao = dao_;
        constitutionalTimelock = constitutionalTimelock_;
        tournamentRegistry = tournamentRegistry_;
        beacon = new UpgradeableBeacon(address(new PlayerVault()), constitutionalTimelock_);
    }

    function create(bytes32 playerId, address playerToken, string calldata name, string calldata symbol)
        external
        returns (address playerVault, address stToken)
    {
        if (playerId == bytes32(0)) revert Errors.ZeroId();
        if (playerToken == address(0)) revert Errors.ZeroAddress();

        playerVault = address(new BeaconProxy(address(beacon), ""));
        stToken = address(new StakedToken(name, symbol, playerVault));

        PlayerVault(playerVault).initialize(
            automator, maintenanceTimelock, dao, tournamentRegistry, playerId, playerToken, stToken
        );

        emit Events.PlayerVaultCreated(playerId, playerVault, stToken);
    }

    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
