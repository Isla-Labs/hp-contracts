// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { ICreateX } from "@createx/ICreateX.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { CreateXAddresses } from "@base/global/libraries/addresses/CreateX.sol";
import { VaultsErrors as Errors } from "@errors/vaults/VaultsErrors.sol";
import { VaultsEvents as Events } from "@events/vaults/VaultsEvents.sol";
import { PlayerVault } from "@vaults/PlayerVault.sol";
import { StakedToken } from "@vaults/StakedToken.sol";

/**
 * @title PlayerVaultFactory
 * @notice Deploys per-market `PlayerVault` beacon proxies + bound `StakedToken`s via CreateX CREATE3.
 * @dev Upgradeable factory (InitGuard TUP). CREATE3 salts are permissioned to the proxy address.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerVaultFactory is Initializable, AddressBook, Ownable {
    ICreateX public constant CREATE_X = ICreateX(CreateXAddresses.CREATE_X);

    UpgradeableBeacon public beacon;

    /// @notice Owns the beacon (logic upgrades); sole caller of `create`
    address public orchestrator;

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    /// @notice Resolve Orchestrator, deploy shared PlayerVault beacon.
    function initialize() external initializer {
        orchestrator = _getAddress(_addressKey(Addresses.ORCHESTRATOR));
        beacon = new UpgradeableBeacon(address(new PlayerVault(address(addressProvider))), orchestrator);
        _transferOwnership(orchestrator);
    }

    /**
     * @notice Deploy a vanity-capable vault + stToken pair and initialize the vault.
     * @param baseName PlayerToken name from Doppler (stToken becomes `Staked {baseName}`).
     * @param baseSymbol PlayerToken symbol from Doppler (stToken becomes `st{baseSymbol}`).
     * @param vaultSalt CreateX salt for the `BeaconProxy` (mine offchain for `0x42…`).
     * @param stTokenSalt CreateX salt for the `StakedToken`.
     */
    function create(
        bytes32 playerId,
        address playerToken,
        string calldata baseName,
        string calldata baseSymbol,
        bytes32 vaultSalt,
        bytes32 stTokenSalt
    ) external returns (address playerVault, address stToken) {
        if (msg.sender != orchestrator) revert Errors.Unauthorized();
        if (playerId == bytes32(0)) revert Errors.ZeroId();
        if (playerToken == address(0)) revert Errors.ZeroAddress();
        if (vaultSalt == bytes32(0) || stTokenSalt == bytes32(0)) revert Errors.ZeroSalt();

        bytes memory vaultInitCode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(address(beacon), ""));
        playerVault = CREATE_X.deployCreate3(vaultSalt, vaultInitCode);

        string memory stName = string.concat("Staked ", baseName);
        string memory stSymbol = string.concat("st", baseSymbol);
        bytes memory stInitCode =
            abi.encodePacked(type(StakedToken).creationCode, abi.encode(stName, stSymbol, playerVault));
        stToken = CREATE_X.deployCreate3(stTokenSalt, stInitCode);

        PlayerVault(playerVault).initialize(playerId, playerToken, stToken);

        emit Events.PlayerVaultCreated(playerId, playerVault, stToken);
    }

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
