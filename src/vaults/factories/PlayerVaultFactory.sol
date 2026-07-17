// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import { PlayerVault } from "@vaults/PlayerVault.sol";
import { StakedToken } from "@vaults/StakedToken.sol";

/**
 * @title PlayerVaultFactory
 * @notice Deploys per-market `PlayerVault` beacon proxies + bound `StakedToken`s.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerVaultFactory {
    UpgradeableBeacon public immutable beacon;
    address public immutable admin;
    address public immutable tournamentRegistry;

    event PlayerVaultCreated(bytes32 indexed playerId, address indexed playerVault, address indexed stToken);

    error ZeroAddress();
    error ZeroId();

    constructor(address admin_, address tournamentRegistry_) {
        if (admin_ == address(0) || tournamentRegistry_ == address(0)) revert ZeroAddress();
        admin = admin_;
        tournamentRegistry = tournamentRegistry_;
        beacon = new UpgradeableBeacon(address(new PlayerVault()), admin_);
    }

    function create(bytes32 playerId, address playerToken, string calldata name, string calldata symbol)
        external
        returns (address playerVault, address stToken)
    {
        if (playerId == bytes32(0)) revert ZeroId();
        if (playerToken == address(0)) revert ZeroAddress();

        playerVault = address(new BeaconProxy(address(beacon), ""));
        stToken = address(new StakedToken(name, symbol, playerVault));

        PlayerVault(playerVault).initialize(admin, tournamentRegistry, playerId, playerToken, stToken);

        emit PlayerVaultCreated(playerId, playerVault, stToken);
    }

    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
