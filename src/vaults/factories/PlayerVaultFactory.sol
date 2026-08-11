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
import { PlayerVault } from "@vaults/PlayerVault.sol";
import { StakedToken } from "@vaults/StakedToken.sol";

/**
 * @title PlayerVaultFactory
 * @notice Immutable factory: deploys per-market `PlayerVault` beacon proxies + bound `StakedToken`s
 *         via CreateX CREATE3.
 * @dev Shared `UpgradeableBeacon` is owned by `TIMELOCK` (delayed logic upgrades). `create` is
 *      Orchestrator-gated via live AddressProvider lookup. Vanity salts (`0x42…`) are mined
 *      offchain (oracle workers) and passed in; CreateX enforces permissioned salts.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerVaultFactory is AddressBook {
    ICreateX public constant CREATE_X = ICreateX(CreateXAddresses.CREATE_X);

    /// @notice Shared beacon for all PlayerVault BeaconProxies (owned by `TIMELOCK`).
    UpgradeableBeacon public immutable beacon;

    /// @param addressProvider_ Canonical `AddressProvider` (`TIMELOCK` must already be set).
    constructor(address addressProvider_) AddressBook(addressProvider_) {
        beacon = new UpgradeableBeacon(
            address(new PlayerVault(addressProvider_)), _getAddress(_addressKey(Addresses.TIMELOCK))
        );
    }

    modifier onlyOrchestrator() {
        if (msg.sender != _getAddress(_addressKey(Addresses.ORCHESTRATOR))) revert Errors.Unauthorized();
        _;
    }

    /**
     * @notice Deploy a vanity-capable vault + stToken pair and initialize the vault.
     * @param baseName PlayerToken name from Doppler (stToken becomes `Staked {baseName}`).
     * @param baseSymbol PlayerToken symbol from Doppler (stToken becomes `{baseSymbol}42`).
     * @param vaultSalt CreateX salt for the `BeaconProxy` (mine offchain for `0x42…`).
     * @param stTokenSalt CreateX salt for the `StakedToken` (deterministic offchain / caller).
     * @param stakedURI ERC-7572 `contractURI` for the stToken (IPFS JSON from FinalConfig).
     */
    function create(
        bytes32 playerId,
        address playerToken,
        string calldata baseName,
        string calldata baseSymbol,
        bytes32 vaultSalt,
        bytes32 stTokenSalt,
        string calldata stakedURI
    ) external onlyOrchestrator returns (address playerVault, address stToken) {
        if (playerId == bytes32(0)) revert Errors.ZeroId();
        if (playerToken == address(0)) revert Errors.ZeroAddress();
        if (vaultSalt == bytes32(0) || stTokenSalt == bytes32(0)) revert Errors.ZeroSalt();
        if (bytes(stakedURI).length == 0) revert Errors.EmptyURI();

        bytes memory vaultInitCode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(address(beacon), ""));
        playerVault = CREATE_X.deployCreate3(vaultSalt, vaultInitCode);

        string memory stName = string.concat("Staked ", baseName);
        string memory stSymbol = string.concat(baseSymbol, "42");
        bytes memory stInitCode = abi.encodePacked(
            type(StakedToken).creationCode, abi.encode(stName, stSymbol, playerVault, stakedURI)
        );
        stToken = CREATE_X.deployCreate3(stTokenSalt, stInitCode);

        PlayerVault(playerVault).initialize(playerId, playerToken, stToken);

        emit Events.PlayerVaultCreated(playerId, playerVault, stToken);
    }

    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
