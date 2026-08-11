// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { MarketsErrors as Errors } from "@errors/markets/MarketsErrors.sol";
import { MarketsEvents as Events } from "@events/markets/MarketsEvents.sol";
import { FeeRouter } from "@markets/FeeRouter.sol";

/**
 * @title FeeRouterFactory
 * @notice Immutable factory: deploys per-market `FeeRouter` beacon proxies.
 * @dev Shared `UpgradeableBeacon` is owned by `TIMELOCK` (delayed logic upgrades). `create` is
 *      Orchestrator-gated via live AddressProvider lookup. Idempotent per `playerId` so
 *      DopplerLocker deploy retries do not orphan FeeRouters after a partial failure.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract FeeRouterFactory is AddressBook {
    /// @notice Shared beacon for all FeeRouter BeaconProxies (owned by `TIMELOCK`).
    UpgradeableBeacon public immutable beacon;

    /// @notice Idempotent resume: `playerId` → deployed FeeRouter (zero until first create).
    mapping(bytes32 playerId => address feeRouter) public feeRouterOf;

    /// @param addressProvider_ Canonical `AddressProvider` (`TIMELOCK` must already be set).
    constructor(address addressProvider_) AddressBook(addressProvider_) {
        beacon = new UpgradeableBeacon(
            address(new FeeRouter(addressProvider_)), _getAddress(_addressKey(Addresses.TIMELOCK))
        );
    }

    modifier onlyOrchestrator() {
        if (msg.sender != _getAddress(_addressKey(Addresses.ORCHESTRATOR))) revert Errors.Unauthorized();
        _;
    }

    /**
     * @notice Deploy a BeaconProxy FeeRouter for `playerId`, or return the existing one.
     * @param playerId Player identity associated with the FeeRouter.
     * @param pbrFeeHub League `PbrFeeHub` (zero = unsupported even-split). Ignored if
     *        a FeeRouter already exists for `playerId` (use `FeeRouter.setPbrFeeHub` to change).
     * @return feeRouter Address of the FeeRouter BeaconProxy.
     */
    function create(bytes32 playerId, address pbrFeeHub) external onlyOrchestrator returns (address feeRouter) {
        if (playerId == bytes32(0)) revert Errors.ZeroId();

        feeRouter = feeRouterOf[playerId];
        if (feeRouter != address(0)) return feeRouter;

        bytes memory initData = abi.encodeCall(FeeRouter.initialize, (playerId, pbrFeeHub));
        feeRouter = address(new BeaconProxy(address(beacon), initData));
        feeRouterOf[playerId] = feeRouter;

        emit Events.FeeRouterCreated(playerId, feeRouter, pbrFeeHub);
    }

    /// @notice Current FeeRouter implementation pointed to by the shared beacon.
    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
