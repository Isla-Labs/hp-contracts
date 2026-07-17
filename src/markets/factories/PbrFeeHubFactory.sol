// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import { MarketsErrors as Errors } from "@base/global/libraries/errors/MarketsErrors.sol";
import { MarketsEvents as Events } from "@base/global/libraries/events/MarketsEvents.sol";
import { PbrFeeHub } from "@markets/PbrFeeHub.sol";

/**
 * @title PbrFeeHubFactory
 * @notice Deploys per-domestic-league `PbrFeeHub` beacon proxies (FeeRouter destinations).
 * @dev Hubs store treasury destinations locally; TournamentExecutor dual-writes them when
 *      competitions are wired. Default weights: 90/9/1 top-level, 89% domestic league share.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrFeeHubFactory {
    UpgradeableBeacon public immutable beacon;
    address public immutable admin;

    /**
     * @param admin_ Granted `ADMIN_ROLE` on each hub; also owns the beacon.
     */
    constructor(address admin_) {
        if (admin_ == address(0)) revert Errors.ZeroAddress();
        admin = admin_;
        beacon = new UpgradeableBeacon(address(new PbrFeeHub()), admin_);
    }

    /**
     * @notice Deploys a league hub with default splits and the league treasury set.
     * @dev Cups / continental / international start empty (100% → league until wired).
     * @param leagueId Domestic league id.
     * @param leagueTreasury Primary domestic-league `PbrTreasury`.
     */
    function create(bytes32 leagueId, address leagueTreasury) external returns (address hub) {
        if (leagueId == bytes32(0)) revert Errors.ZeroId();
        if (leagueTreasury == address(0)) revert Errors.ZeroAddress();

        bytes memory initData = abi.encodeCall(PbrFeeHub.initialize, (admin, leagueId, leagueTreasury));
        hub = address(new BeaconProxy(address(beacon), initData));
        emit Events.PbrFeeHubCreated(leagueId, hub);
    }

    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
