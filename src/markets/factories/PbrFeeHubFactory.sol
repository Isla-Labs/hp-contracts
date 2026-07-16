// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import { PbrFeeHub } from "@markets/PbrFeeHub.sol";

/**
 * @title PbrFeeHubFactory
 * @notice Deploys per-domestic-league `PbrFeeHub` beacon proxies (FeeRouter destinations).
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

    /**
     * @notice Deploys a league hub with default 90/9/1 top-level split and 89:11 domestic sub-split.
     * @param leagueId Domestic league id.
     * @param leagueTreasury Primary domestic league `PbrTreasury`.
     * @param domesticCups Domestic cup treasuries (even split of the 11% domestic cup share).
     * @param continentalTreasuries Continental destinations (e.g. UCL, UEL, UECL).
     * @param continentalWeights Relative weights (e.g. 5, 3, 1).
     * @param internationalTreasury International pot treasury.
     */
    function create(
        bytes32 leagueId,
        address leagueTreasury,
        address[] calldata domesticCups,
        address[] calldata continentalTreasuries,
        uint16[] calldata continentalWeights,
        address internationalTreasury
    ) external returns (address hub) {
        if (leagueId == bytes32(0)) revert ZeroId();

        bytes memory initData = abi.encodeCall(
            PbrFeeHub.initialize,
            (
                admin,
                leagueId,
                leagueTreasury,
                domesticCups,
                continentalTreasuries,
                continentalWeights,
                internationalTreasury
            )
        );
        hub = address(new BeaconProxy(address(beacon), initData));
        emit PbrFeeHubCreated(leagueId, hub);
    }

    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
