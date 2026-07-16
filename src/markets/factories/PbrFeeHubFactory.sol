// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import { PbrFeeHub } from "@markets/PbrFeeHub.sol";

/**
 * @title PbrFeeHubFactory
 * @notice Deploys per-league `PbrFeeHub` beacon proxies (FeeRouter destinations).
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrFeeHubFactory {
    UpgradeableBeacon public immutable beacon;
    address public immutable admin;

    event PbrFeeHubCreated(bytes32 indexed leagueId, address indexed pbrFeeHub);

    error ZeroAddress();
    error ZeroId();

    constructor(address admin_) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
        beacon = new UpgradeableBeacon(address(new PbrFeeHub()), admin_);
    }

    function create(bytes32 leagueId, address[] calldata treasuries, uint16[] calldata bps)
        external
        returns (address hub)
    {
        if (leagueId == bytes32(0)) revert ZeroId();

        bytes memory initData = abi.encodeCall(PbrFeeHub.initialize, (admin, leagueId, treasuries, bps));
        hub = address(new BeaconProxy(address(beacon), initData));
        emit PbrFeeHubCreated(leagueId, hub);
    }

    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
