// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import { PbrTreasury } from "../PbrTreasury.sol";

/**
 * @title PbrTreasuryFactory
 * @notice Deploys per-tournament `PbrTreasury` beacon proxies.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrTreasuryFactory {
    UpgradeableBeacon public immutable beacon;
    address public immutable admin;
    address public immutable tournamentRegistry;

    event PbrTreasuryCreated(bytes32 indexed tournamentId, address indexed pbrTreasury, uint16 initialSeason);

    error ZeroAddress();
    error ZeroId();
    error ZeroSeason();

    constructor(address admin_, address tournamentRegistry_) {
        if (admin_ == address(0) || tournamentRegistry_ == address(0)) revert ZeroAddress();
        admin = admin_;
        tournamentRegistry = tournamentRegistry_;
        beacon = new UpgradeableBeacon(address(new PbrTreasury(tournamentRegistry_)), admin_);
    }

    function create(bytes32 tournamentId, uint16 initialSeason) external returns (address pbrTreasury) {
        if (tournamentId == bytes32(0)) revert ZeroId();
        if (initialSeason == 0) revert ZeroSeason();

        bytes memory initData = abi.encodeCall(PbrTreasury.initialize, (admin, tournamentId, initialSeason));

        pbrTreasury = address(new BeaconProxy(address(beacon), initData));
        emit PbrTreasuryCreated(tournamentId, pbrTreasury, initialSeason);
    }

    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
