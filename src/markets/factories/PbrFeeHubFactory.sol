// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { MarketsErrors as Errors } from "@errors/markets/MarketsErrors.sol";
import { MarketsEvents as Events } from "@events/markets/MarketsEvents.sol";
import { IPbrFeeHubFactory } from "@interfaces/markets/factories/IPbrFeeHubFactory.sol";
import { PbrFeeHub } from "@markets/PbrFeeHub.sol";

/**
 * @title PbrFeeHubFactory
 * @notice Deploys per-domestic-league `PbrFeeHub` beacon proxies (FeeRouter destinations).
 * @dev Beacon ownership (logic upgrades) is assigned to `ConstitutionalTimelock`. Hubs store
 *      treasury destinations locally; default weights: 90/9/1 top-level, 89% domestic league share.
 *      `create` is restricted to `CREATE_TOURNAMENT` (cat-1 orchestrator via ConstitutionalTimelock).
 *      Protocol addresses are resolved once from `AddressProvider` in the factory constructor.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrFeeHubFactory is AddressBook, IPbrFeeHubFactory {
    UpgradeableBeacon public immutable beacon;

    /// @notice Granted `CATEGORY_TWO` on each hub
    address public immutable maintenanceTimelock;

    /// @notice Granted `CATEGORY_ONE` on each hub; owns the beacon
    address public immutable constitutionalTimelock;

    /// @notice Granted `DEFAULT_ADMIN_ROLE` on each hub
    address public immutable dao;

    /// @notice Sole caller of `create`
    address public immutable createTournament;

    /**
     * @param addressProvider_ Canonical `AddressProvider` — resolves governance + orchestrator deps.
     */
    constructor(address addressProvider_) AddressBook(addressProvider_) {
        maintenanceTimelock = _getAddress(_addressKey(Addresses.MAINTENANCE_TIMELOCK));
        constitutionalTimelock = _getAddress(_addressKey(Addresses.CONSTITUTIONAL_TIMELOCK));
        dao = _getAddress(_addressKey(Addresses.DAO));
        createTournament = _getAddress(_addressKey(Addresses.CREATE_TOURNAMENT));
        beacon = new UpgradeableBeacon(address(new PbrFeeHub(addressProvider_)), constitutionalTimelock);
    }

    /**
     * @notice Deploys a league hub with default splits and the league treasury set.
     * @dev Cups / continental / international start empty (100% → league until wired).
     * @param leagueId Domestic league id.
     * @param leagueTreasury Primary domestic-league `PbrTreasury`.
     */
    function create(bytes32 leagueId, address leagueTreasury) external returns (address hub) {
        if (msg.sender != createTournament) revert Errors.Unauthorized();
        if (leagueId == bytes32(0)) revert Errors.ZeroId();
        if (leagueTreasury == address(0)) revert Errors.ZeroAddress();

        bytes memory initData = abi.encodeCall(PbrFeeHub.initialize, (leagueId, leagueTreasury));
        hub = address(new BeaconProxy(address(beacon), initData));
        emit Events.PbrFeeHubCreated(leagueId, hub);
    }

    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
