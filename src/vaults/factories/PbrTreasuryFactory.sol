// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import { ICreateX } from "@createx/ICreateX.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { CreateXAddresses } from "@base/global/libraries/addresses/CreateX.sol";
import { VaultsErrors as Errors } from "@errors/vaults/VaultsErrors.sol";
import { VaultsEvents as Events } from "@events/vaults/VaultsEvents.sol";
import { IPbrTreasuryFactory } from "@interfaces/vaults/factories/IPbrTreasuryFactory.sol";
import { PbrTreasury } from "@vaults/PbrTreasury.sol";

/**
 * @title PbrTreasuryFactory
 * @notice Immutable factory: deploys per-tournament `PbrTreasury` beacon proxies via CreateX CREATE3.
 * @dev Shared `UpgradeableBeacon` is owned by `TIMELOCK` (delayed logic upgrades). `create` is
 *      `TournamentInitializer`-gated via live AddressProvider lookup. Vanity salts (`0x99…`) are
 *      mined offchain (oracle workers) and passed in; CreateX enforces permissioned salts.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrTreasuryFactory is AddressBook, IPbrTreasuryFactory {
    ICreateX public constant CREATE_X = ICreateX(CreateXAddresses.CREATE_X);

    /// @notice Shared beacon for all PbrTreasury BeaconProxies (owned by `TIMELOCK`).
    UpgradeableBeacon public immutable beacon;

    /// @param addressProvider_ Canonical `AddressProvider` (`TIMELOCK` must already be set).
    constructor(address addressProvider_) AddressBook(addressProvider_) {
        beacon = new UpgradeableBeacon(
            address(new PbrTreasury(addressProvider_)), _getAddress(_addressKey(Addresses.TIMELOCK))
        );
    }

    modifier onlyTournamentInitializer() {
        if (msg.sender != _getAddress(_addressKey(Addresses.TOURNAMENT_INITIALIZER))) {
            revert Errors.Unauthorized();
        }
        _;
    }

    /**
     * @notice Deploy a vanity-capable tournament treasury and initialize it.
     * @param salt CreateX salt for the `BeaconProxy` (mine offchain for `0x99…`).
     */
    function create(
        bytes32 tournamentId,
        uint16 initialSeasonStartYear,
        bytes32 salt
    ) external onlyTournamentInitializer returns (address pbrTreasury) {
        if (tournamentId == bytes32(0)) revert Errors.ZeroId();
        if (initialSeasonStartYear == 0) revert Errors.ZeroSeason();
        if (salt == bytes32(0)) revert Errors.ZeroSalt();

        bytes memory initData = abi.encodeCall(PbrTreasury.initialize, (tournamentId, initialSeasonStartYear));
        bytes memory initCode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(address(beacon), initData));

        pbrTreasury = CREATE_X.deployCreate3(salt, initCode);

        emit Events.PbrTreasuryCreated(tournamentId, pbrTreasury, initialSeasonStartYear);
    }

    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
