// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import { VaultsErrors as Errors } from "@base/global/libraries/errors/VaultsErrors.sol";
import { VaultsEvents as Events } from "@base/global/libraries/events/VaultsEvents.sol";
import { PbrTreasury } from "@vaults/PbrTreasury.sol";

/**
 * @title PbrTreasuryFactory
 * @notice Deploys per-tournament `PbrTreasury` beacon proxies.
 * @dev Beacon ownership (logic upgrades) is assigned to `ConstitutionalTimelock`.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrTreasuryFactory {
    UpgradeableBeacon public immutable beacon;

    /// @notice Granted `CATEGORY_THREE` on each treasury
    address public immutable automator;

    /// @notice Granted `CATEGORY_TWO` on each treasury
    address public immutable maintenanceTimelock;

    /// @notice Owns the beacon (logic upgrades)
    address public immutable constitutionalTimelock;

    /// @notice Granted `DEFAULT_ADMIN_ROLE` on each treasury
    address public immutable dao;

    address public immutable tournamentRegistry;

    constructor(
        address automator_,
        address maintenanceTimelock_,
        address constitutionalTimelock_,
        address dao_,
        address tournamentRegistry_
    ) {
        if (
            automator_ == address(0) || maintenanceTimelock_ == address(0) || constitutionalTimelock_ == address(0)
                || dao_ == address(0) || tournamentRegistry_ == address(0)
        ) revert Errors.ZeroAddress();

        automator = automator_;
        maintenanceTimelock = maintenanceTimelock_;
        constitutionalTimelock = constitutionalTimelock_;
        dao = dao_;
        tournamentRegistry = tournamentRegistry_;
        beacon = new UpgradeableBeacon(address(new PbrTreasury(tournamentRegistry_)), constitutionalTimelock_);
    }

    function create(bytes32 tournamentId, uint16 initialSeason) external returns (address pbrTreasury) {
        if (tournamentId == bytes32(0)) revert Errors.ZeroId();
        if (initialSeason == 0) revert Errors.ZeroSeason();

        bytes memory initData =
            abi.encodeCall(PbrTreasury.initialize, (automator, maintenanceTimelock, dao, tournamentId, initialSeason));

        pbrTreasury = address(new BeaconProxy(address(beacon), initData));
        emit Events.PbrTreasuryCreated(tournamentId, pbrTreasury, initialSeason);
    }

    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
