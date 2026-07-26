// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import { Minter } from "@stabilityeth/Minter.sol";

/**
 * @title MinterFactory
 * @notice Deploys per-`appId` `Minter` beacon proxies for `AppRegistry`.
 * @dev Beacon ownership (logic upgrades) is assigned to `beaconOwner` at construction.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract MinterFactory is Ownable {
    /// @notice Shared beacon; upgrade to change logic for every app Minter
    UpgradeableBeacon public immutable beacon;

    /// @notice StabilityETH wrapper passed into each Minter
    address public immutable seth;

    /// @notice Sole caller of `create` (set once to `AppRegistry`)
    address public registry;

    event RegistryUpdated(address indexed registry);
    event MinterCreated(bytes32 indexed appId, address indexed minter);

    error ZeroAddress();
    error ZeroAppId();
    error NotRegistry();
    error RegistryAlreadySet();

    modifier onlyRegistry() {
        if (msg.sender != registry) revert NotRegistry();
        _;
    }

    /**
     * @param seth_ StabilityETH wrapper.
     * @param owner_ Owns the factory (`setRegistry`).
     * @param beaconOwner_ Owns the shared `UpgradeableBeacon`.
     */
    constructor(address seth_, address owner_, address beaconOwner_) Ownable(owner_) {
        if (seth_ == address(0) || beaconOwner_ == address(0)) revert ZeroAddress();
        seth = seth_;
        beacon = new UpgradeableBeacon(address(new Minter()), beaconOwner_);
    }

    /// @notice One-time bind to `AppRegistry`
    function setRegistry(
        address registry_
    ) external onlyOwner {
        if (registry_ == address(0)) revert ZeroAddress();
        if (registry != address(0)) revert RegistryAlreadySet();
        registry = registry_;
        emit RegistryUpdated(registry_);
    }

    /**
     * @notice Deploys a BeaconProxy Minter for `appId` and initializes it.
     * @return minter Address of the new proxy.
     */
    function create(
        bytes32 appId
    ) external onlyRegistry returns (address minter) {
        if (appId == bytes32(0)) revert ZeroAppId();

        bytes memory initData = abi.encodeCall(Minter.initialize, (seth, appId, msg.sender));
        minter = address(new BeaconProxy(address(beacon), initData));

        emit MinterCreated(appId, minter);
    }

    /// @notice Current Minter implementation pointed to by the shared beacon
    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
