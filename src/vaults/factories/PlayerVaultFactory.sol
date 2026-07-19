// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import { ICreateX } from "@createx/ICreateX.sol";

import { CreateXAddresses } from "@base/global/libraries/addresses/CreateX.sol";
import { VaultsErrors as Errors } from "@base/global/libraries/errors/VaultsErrors.sol";
import { VaultsEvents as Events } from "@base/global/libraries/events/VaultsEvents.sol";
import { PlayerVault } from "@vaults/PlayerVault.sol";
import { StakedToken } from "@vaults/StakedToken.sol";

/**
 * @title PlayerVaultFactory
 * @notice Deploys per-market `PlayerVault` beacon proxies + bound `StakedToken`s via CreateX CREATE3.
 * @dev Beacon ownership (logic upgrades) is assigned to `ConstitutionalTimelock`.
 *      CREATE3 addresses depend only on CreateX + this factory's guarded salt (not initcode), so
 *      vanity prefixes (e.g. `0x42…` vault / stToken) can be mined offline against `computeCreate3Address`.
 *      Prefer permissioned salts: `address(this) || 0x00 || entropy11` via `makeSalt`.
 *      `create` is restricted to `automator` to prevent salt sniping.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerVaultFactory {
    ICreateX public constant CREATE_X = ICreateX(CreateXAddresses.CREATE_X);

    UpgradeableBeacon public immutable beacon;

    /// @notice Granted `CATEGORY_THREE` on each vault; sole caller of `create`
    address public immutable automator;

    /// @notice Granted `CATEGORY_TWO` on each vault
    address public immutable maintenanceTimelock;

    /// @notice Granted `DEFAULT_ADMIN_ROLE` on each vault (pause)
    address public immutable dao;

    /// @notice Owns the beacon (logic upgrades)
    address public immutable constitutionalTimelock;

    address public immutable tournamentRegistry;
    address public immutable playerSetRegistry;

    constructor(
        address automator_,
        address maintenanceTimelock_,
        address dao_,
        address constitutionalTimelock_,
        address tournamentRegistry_,
        address playerSetRegistry_
    ) {
        if (
            automator_ == address(0) || maintenanceTimelock_ == address(0) || dao_ == address(0)
                || constitutionalTimelock_ == address(0) || tournamentRegistry_ == address(0)
                || playerSetRegistry_ == address(0)
        ) revert Errors.ZeroAddress();

        automator = automator_;
        maintenanceTimelock = maintenanceTimelock_;
        dao = dao_;
        constitutionalTimelock = constitutionalTimelock_;
        tournamentRegistry = tournamentRegistry_;
        playerSetRegistry = playerSetRegistry_;
        beacon = new UpgradeableBeacon(address(new PlayerVault()), constitutionalTimelock_);
    }

    /**
     * @notice Deploy a vanity-capable vault + stToken pair and initialize the vault.
     * @param baseName PlayerToken name from Doppler (stToken becomes `Staked {baseName}`).
     * @param baseSymbol PlayerToken symbol from Doppler (stToken becomes `st{baseSymbol}`).
     * @param vaultSalt CreateX salt for the `BeaconProxy` (mine for desired prefix).
     * @param expectedVault Address from `computeCreate3Address(vaultSalt)`.
     * @param stTokenSalt CreateX salt for the `StakedToken`.
     * @param expectedStToken Address from `computeCreate3Address(stTokenSalt)`.
     */
    function create(
        bytes32 playerId,
        address playerToken,
        string calldata baseName,
        string calldata baseSymbol,
        bytes32 vaultSalt,
        address expectedVault,
        bytes32 stTokenSalt,
        address expectedStToken
    ) external returns (address playerVault, address stToken) {
        if (msg.sender != automator) revert Errors.Unauthorized();
        if (playerId == bytes32(0)) revert Errors.ZeroId();
        if (playerToken == address(0) || expectedVault == address(0) || expectedStToken == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (vaultSalt == bytes32(0) || stTokenSalt == bytes32(0)) revert Errors.ZeroSalt();

        bytes memory vaultInitCode =
            abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(address(beacon), ""));
        playerVault = CREATE_X.deployCreate3(vaultSalt, vaultInitCode);
        if (playerVault != expectedVault) revert Errors.AddressMismatch(playerVault, expectedVault);

        string memory stName = string.concat("Staked ", baseName);
        string memory stSymbol = string.concat("st", baseSymbol);
        bytes memory stInitCode =
            abi.encodePacked(type(StakedToken).creationCode, abi.encode(stName, stSymbol, playerVault));
        stToken = CREATE_X.deployCreate3(stTokenSalt, stInitCode);
        if (stToken != expectedStToken) revert Errors.AddressMismatch(stToken, expectedStToken);

        PlayerVault(playerVault).initialize(
            automator,
            maintenanceTimelock,
            dao,
            tournamentRegistry,
            playerSetRegistry,
            playerId,
            playerToken,
            stToken
        );

        emit Events.PlayerVaultCreated(playerId, playerVault, stToken);
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

        // CreateX hashes non-pseudo-random salts so guard modes cannot be bypassed.
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
