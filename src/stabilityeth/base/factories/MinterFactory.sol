// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";

import { Minter } from "@stabilityeth/Minter.sol";

/**
 * @title MinterFactory
 * @notice Deploys per-`appId` immutable `Minter` contracts for `AppRegistry`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract MinterFactory is Ownable {
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
     */
    constructor(address seth_, address owner_) Ownable(owner_) {
        if (seth_ == address(0)) revert ZeroAddress();
        seth = seth_;
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
     * @notice Deploys an immutable Minter for `appId`.
     * @return minter Address of the new Minter.
     */
    function create(
        bytes32 appId
    ) external onlyRegistry returns (address minter) {
        if (appId == bytes32(0)) revert ZeroAppId();

        minter = address(new Minter(seth, appId, msg.sender));

        emit MinterCreated(appId, minter);
    }
}
