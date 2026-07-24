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
 * @notice Deploys per-tournament `PbrTreasury` beacon proxies via CreateX CREATE3.
 * @dev Beacon ownership (logic upgrades) is assigned to `ConstitutionalTimelock`.
 *      CREATE3 addresses depend only on CreateX + this factory's guarded salt (not initcode), so
 *      vanity prefixes (e.g. `0x99…`) can be mined offline against `computeCreate3Address`.
 *      Prefer permissioned salts: `address(this) || 0x00 || entropy11` via `makeSalt`.
 *      `create` is restricted to `CREATE_TOURNAMENT` (cat-1 orchestrator via ConstitutionalTimelock).
 *      Protocol addresses are resolved once from `AddressProvider` in the factory constructor.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrTreasuryFactory is AddressBook, IPbrTreasuryFactory {
    ICreateX public constant CREATE_X = ICreateX(CreateXAddresses.CREATE_X);

    UpgradeableBeacon public immutable beacon;

    /// @notice Granted `CATEGORY_THREE` on each treasury
    address public immutable automator;

    /// @notice Granted `CATEGORY_TWO` on each treasury
    address public immutable maintenanceTimelock;

    /// @notice Owns the beacon (logic upgrades)
    address public immutable constitutionalTimelock;

    /// @notice Granted `DEFAULT_ADMIN_ROLE` on each treasury
    address public immutable dao;

    /// @notice Sole caller of `create`; granted `CATEGORY_ONE` on each treasury
    address public immutable createTournament;

    address public immutable tournamentRegistry;
    address public immutable playerSetRegistry;

    /**
     * @param addressProvider_ Canonical `AddressProvider` — resolves governance + registry deps.
     */
    constructor(address addressProvider_) AddressBook(addressProvider_) {
        automator = _getAddress(_addressKey(Addresses.AUTOMATOR));
        maintenanceTimelock = _getAddress(_addressKey(Addresses.MAINTENANCE_TIMELOCK));
        constitutionalTimelock = _getAddress(_addressKey(Addresses.CONSTITUTIONAL_TIMELOCK));
        dao = _getAddress(_addressKey(Addresses.DAO));
        createTournament = _getAddress(_addressKey(Addresses.CREATE_TOURNAMENT));
        tournamentRegistry = _getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY));
        playerSetRegistry = _getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY));
        beacon = new UpgradeableBeacon(address(new PbrTreasury(addressProvider_)), constitutionalTimelock);
    }

    /**
     * @notice Deploy a vanity-capable tournament treasury and initialize it.
     * @param salt CreateX salt for the `BeaconProxy` (mine for `0x99…` prefix).
     * @param expected Address from `computeCreate3Address(salt)`.
     */
    function create(
        bytes32 tournamentId,
        uint16 initialSeason,
        bytes32 salt,
        address expected
    ) external returns (address pbrTreasury) {
        if (msg.sender != createTournament) revert Errors.Unauthorized();
        if (tournamentId == bytes32(0)) revert Errors.ZeroId();
        if (initialSeason == 0) revert Errors.ZeroSeason();
        if (expected == address(0)) revert Errors.ZeroAddress();
        if (salt == bytes32(0)) revert Errors.ZeroSalt();

        bytes memory initData = abi.encodeCall(PbrTreasury.initialize, (tournamentId, initialSeason));

        bytes memory initCode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(address(beacon), initData));

        pbrTreasury = CREATE_X.deployCreate3(salt, initCode);
        if (pbrTreasury != expected) revert Errors.AddressMismatch(pbrTreasury, expected);

        emit Events.PbrTreasuryCreated(tournamentId, pbrTreasury, initialSeason);
    }

    // --------------------------------------------
    //  Salt / address helpers (for vanity mining)
    // --------------------------------------------

    /**
     * @notice Builds a CreateX salt permissioned to this factory: `address(this) || 0x00 || entropy`.
     * @dev Byte 21 `0x00` = permissioned deploy, no cross-chain redeploy guard. Last 11 bytes are mineable.
     */
    function makeSalt(bytes11 entropy) external view returns (bytes32) {
        return bytes32(uint256(uint160(address(this)))) << 96 | bytes32(uint256(uint88(entropy)));
    }

    /// @notice Guarded salt CreateX will use when this factory is `msg.sender`.
    function computeGuardedSalt(bytes32 salt) public view returns (bytes32) {
        address senderBytes = address(bytes20(salt));
        bytes1 redeployProtectionFlag = salt[20];

        if (senderBytes == address(this)) {
            if (redeployProtectionFlag == hex"00") {
                return _efficientHash(bytes32(uint256(uint160(address(this)))), salt);
            }
            if (redeployProtectionFlag == hex"01") {
                return keccak256(abi.encode(address(this), block.chainid, salt));
            }
            revert Errors.InvalidSalt();
        }

        if (senderBytes == address(0) && redeployProtectionFlag == hex"01") {
            return _efficientHash(bytes32(block.chainid), salt);
        }

        return keccak256(abi.encode(salt));
    }

    /// @notice Predicted CREATE3 address for `salt` when deployed through this factory.
    function computeCreate3Address(bytes32 salt) external view returns (address) {
        return CREATE_X.computeCreate3Address(computeGuardedSalt(salt));
    }

    function implementation() external view returns (address) {
        return beacon.implementation();
    }

    function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            hash := keccak256(0x00, 0x40)
        }
    }
}
