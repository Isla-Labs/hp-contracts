// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { TransparentUpgradeableProxy } from "@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol";

import { TournamentRegistry } from "@src/TournamentRegistry.sol";

/**
 * @title TournamentRegistryFactory
 * @notice Deploys `TournamentRegistry` behind a `TransparentUpgradeableProxy`.
 * @dev OZ v5 auto-deploys a `ProxyAdmin` owned by `admin`. That address is also granted
 *      `ADMIN_ROLE` on the registry via `initialize`. Prefer `LifecycleTimelock` for both.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TournamentRegistryFactory {
    /// @notice Logic contract pointed to by the proxy
    address public immutable implementation;

    /// @notice Proxy address — use this as the canonical TournamentRegistry
    address public immutable proxy;

    /// @notice Granted `ADMIN_ROLE` on the registry; also owns the ProxyAdmin
    address public immutable admin;

    /// @notice Emitted when the TournamentRegistry proxy is deployed
    event TournamentRegistryCreated(address indexed proxy, address indexed implementation, address indexed admin);

    /// @notice Thrown when a required address is zero
    error ZeroAddress();

    /**
     * @param admin_ Address granted `ADMIN_ROLE` and ownership of the auto-deployed ProxyAdmin.
     */
    constructor(address admin_) {
        if (admin_ == address(0)) revert ZeroAddress();

        admin = admin_;
        implementation = address(new TournamentRegistry());

        bytes memory initData = abi.encodeCall(TournamentRegistry.initialize, (admin_));
        proxy = address(new TransparentUpgradeableProxy(implementation, admin_, initData));

        emit TournamentRegistryCreated(proxy, implementation, admin_);
    }
}
