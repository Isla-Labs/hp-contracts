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
 * @notice Deploys per-market `BeaconProxy` FeeRouters sharing one `UpgradeableBeacon`.
 * @dev Beacon ownership (logic upgrades) is assigned to `Orchestrator`. Each `create`
 *      call deploys a thin proxy with player-specific storage via `FeeRouter.initialize`.
 *      `create` is restricted to `Orchestrator`. Protocol addresses are resolved once from
 *      `AddressProvider` in the factory constructor.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract FeeRouterFactory is AddressBook {
    /// @notice Shared beacon; upgrade to change logic for every market FeeRouter
    UpgradeableBeacon public immutable beacon;

    /// @notice Owns the beacon (logic upgrades); sole caller of `create`
    address public immutable orchestrator;

    /**
     * @param addressProvider_ Canonical `AddressProvider` — resolves orchestrator.
     */
    constructor(address addressProvider_) AddressBook(addressProvider_) {
        orchestrator = _getAddress(_addressKey(Addresses.ORCHESTRATOR));

        address impl = address(new FeeRouter(addressProvider_));
        beacon = new UpgradeableBeacon(impl, orchestrator);
    }

    /**
     * @notice Deploys a BeaconProxy FeeRouter for `playerId` and initializes per-market state.
     * @param playerId Player identity associated with the FeeRouter.
     * @param pbrFeeHub League `PbrFeeHub` (zero = unsupported even-split).
     * @return feeRouter Address of the newly deployed BeaconProxy.
     */
    function create(bytes32 playerId, address pbrFeeHub) external returns (address feeRouter) {
        if (msg.sender != orchestrator) revert Errors.Unauthorized();
        if (playerId == bytes32(0)) revert Errors.ZeroId();

        bytes memory initData = abi.encodeCall(FeeRouter.initialize, (playerId, pbrFeeHub));

        feeRouter = address(new BeaconProxy(address(beacon), initData));

        emit Events.FeeRouterCreated(playerId, feeRouter, pbrFeeHub);
    }

    /// @notice Current FeeRouter implementation pointed to by the shared beacon
    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
