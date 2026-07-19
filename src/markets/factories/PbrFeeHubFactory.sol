// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import { MarketsErrors as Errors } from "@base/global/libraries/errors/MarketsErrors.sol";
import { MarketsEvents as Events } from "@base/global/libraries/events/MarketsEvents.sol";
import { IPbrFeeHubFactory } from "@base/global/interfaces/markets/factories/IPbrFeeHubFactory.sol";
import { PbrFeeHub } from "@markets/PbrFeeHub.sol";

/**
 * @title PbrFeeHubFactory
 * @notice Deploys per-domestic-league `PbrFeeHub` beacon proxies (FeeRouter destinations).
 * @dev Beacon ownership (logic upgrades) is assigned to `ConstitutionalTimelock`. Hubs store
 *      treasury destinations locally; default weights: 90/9/1 top-level, 89% domestic league share.
 *      `create` is restricted to `deployTournament` (cat-1 orchestrator via ConstitutionalTimelock).
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrFeeHubFactory is IPbrFeeHubFactory {
    UpgradeableBeacon public immutable beacon;

    /// @notice Granted `CATEGORY_TWO` on each hub
    address public immutable maintenanceTimelock;

    /// @notice Granted `CATEGORY_ONE` on each hub; owns the beacon
    address public immutable constitutionalTimelock;

    /// @notice Granted `DEFAULT_ADMIN_ROLE` on each hub
    address public immutable dao;

    /// @notice Sole caller of `create`
    address public immutable deployTournament;

    /**
     * @param maintenanceTimelock_ `MaintenanceTimelock` — cat-2 on each hub.
     * @param constitutionalTimelock_ `ConstitutionalTimelock` — cat-1 + beacon owner.
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE` on each hub.
     * @param deployTournament_ `DeployTournament` — sole caller of `create`.
     */
    constructor(
        address maintenanceTimelock_,
        address constitutionalTimelock_,
        address dao_,
        address deployTournament_
    ) {
        if (
            maintenanceTimelock_ == address(0) || constitutionalTimelock_ == address(0) || dao_ == address(0)
                || deployTournament_ == address(0)
        ) {
            revert Errors.ZeroAddress();
        }
        maintenanceTimelock = maintenanceTimelock_;
        constitutionalTimelock = constitutionalTimelock_;
        dao = dao_;
        deployTournament = deployTournament_;
        beacon = new UpgradeableBeacon(address(new PbrFeeHub()), constitutionalTimelock_);
    }

    /**
     * @notice Deploys a league hub with default splits and the league treasury set.
     * @dev Cups / continental / international start empty (100% → league until wired).
     * @param leagueId Domestic league id.
     * @param leagueTreasury Primary domestic-league `PbrTreasury`.
     */
    function create(bytes32 leagueId, address leagueTreasury) external returns (address hub) {
        if (msg.sender != deployTournament) revert Errors.Unauthorized();
        if (leagueId == bytes32(0)) revert Errors.ZeroId();
        if (leagueTreasury == address(0)) revert Errors.ZeroAddress();

        bytes memory initData = abi.encodeCall(
            PbrFeeHub.initialize,
            (maintenanceTimelock, constitutionalTimelock, dao, deployTournament, leagueId, leagueTreasury)
        );
        hub = address(new BeaconProxy(address(beacon), initData));
        emit Events.PbrFeeHubCreated(leagueId, hub);
    }

    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
