// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { MarketsErrors as Errors } from "@errors/markets/MarketsErrors.sol";
import { MarketsEvents as Events } from "@events/markets/MarketsEvents.sol";
import { IPbrFeeHubFactory } from "@interfaces/markets/factories/IPbrFeeHubFactory.sol";
import { PbrFeeHub } from "@markets/PbrFeeHub.sol";

/**
 * @title PbrFeeHubFactory
 * @notice Deploys per-domestic-league `PbrFeeHub` beacon proxies (FeeRouter destinations).
 * @dev Upgradeable factory (InitGuard TUP). Beacon ownership → Orchestrator.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrFeeHubFactory is Initializable, AddressBook, Ownable, IPbrFeeHubFactory {
    UpgradeableBeacon public beacon;

    /// @notice Owns the beacon (logic upgrades); sole caller of `create`
    address public orchestrator;

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    /// @notice Resolve Orchestrator, deploy shared PbrFeeHub beacon.
    function initialize() external initializer {
        orchestrator = _getAddress(_addressKey(Addresses.ORCHESTRATOR));
        beacon = new UpgradeableBeacon(address(new PbrFeeHub(address(addressProvider))), orchestrator);
        _transferOwnership(orchestrator);
    }

    /**
     * @notice Deploys a league hub with default splits and the league treasury set.
     * @dev Cups / continental / international start empty (100% → league until wired).
     * @param leagueId Domestic league id.
     * @param leagueTreasury Primary domestic-league `PbrTreasury`.
     */
    function create(bytes32 leagueId, address leagueTreasury) external returns (address hub) {
        if (msg.sender != orchestrator) revert Errors.Unauthorized();
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
