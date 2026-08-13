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
 * @notice Immutable factory: deploys per-domestic-league `PbrFeeHub` beacon proxies.
 * @dev Shared `UpgradeableBeacon` is owned by `TIMELOCK` (delayed logic upgrades). `create` is
 *      `TournamentInitializer`-gated via live AddressProvider lookup.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrFeeHubFactory is AddressBook, IPbrFeeHubFactory {
    /// @notice Shared beacon for all PbrFeeHub BeaconProxies (owned by `TIMELOCK`).
    UpgradeableBeacon public immutable beacon;

    /// @param addressProvider_ Canonical `AddressProvider` (`TIMELOCK` must already be set).
    constructor(address addressProvider_) AddressBook(addressProvider_) {
        beacon = new UpgradeableBeacon(
            address(new PbrFeeHub(addressProvider_)), _getAddress(_addressKey(Addresses.TIMELOCK))
        );
    }

    modifier onlyTournamentInitializer() {
        if (msg.sender != _getAddress(_addressKey(Addresses.TOURNAMENT_INITIALIZER))) {
            revert Errors.Unauthorized();
        }
        _;
    }

    /**
     * @notice Deploys a league hub with default splits and the league treasury set.
     * @dev Cups / continental / international start empty (100% → league until wired).
     * @param leagueId Domestic league id.
     * @param leagueTreasury Primary domestic-league `PbrTreasury`.
     */
    function create(bytes32 leagueId, address leagueTreasury) external onlyTournamentInitializer returns (address hub) {
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
