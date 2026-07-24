// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { MarketsErrors as Errors } from "@errors/markets/MarketsErrors.sol";
import { MarketsEvents as Events } from "@events/markets/MarketsEvents.sol";
import { FeeRouter } from "@markets/FeeRouter.sol";

/**
 * @title FeeRouterFactory
 * @notice Deploys per-market `BeaconProxy` FeeRouters sharing one `UpgradeableBeacon`.
 * @dev Beacon ownership (logic upgrades) is assigned to `ConstitutionalTimelock`. Each `create`
 *      call deploys a thin proxy with player-specific storage via `FeeRouter.initialize`.
 *      Protocol addresses are resolved once from `AddressProvider` in the factory constructor.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract FeeRouterFactory is AddressBook {
    /// @notice Shared beacon; upgrade to change logic for every market FeeRouter
    UpgradeableBeacon public immutable beacon;

    /// @notice Granted `CATEGORY_THREE` on every deployed FeeRouter
    address public immutable automator;

    /// @notice Granted `CATEGORY_TWO` on every deployed FeeRouter
    address public immutable maintenanceTimelock;

    /// @notice Granted `CATEGORY_ONE` on every deployed FeeRouter; owns the beacon
    address public immutable constitutionalTimelock;

    /// @notice Granted `DEFAULT_ADMIN_ROLE` on every deployed FeeRouter
    address public immutable dao;

    /**
     * @param addressProvider_ Canonical `AddressProvider` — resolves governance + registry deps.
     */
    constructor(address addressProvider_) AddressBook(addressProvider_) {
        automator = _getAddress(_addressKey(Keys.AUTOMATOR));
        maintenanceTimelock = _getAddress(_addressKey(Keys.MAINTENANCE_TIMELOCK));
        constitutionalTimelock = _getAddress(_addressKey(Keys.CONSTITUTIONAL_TIMELOCK));
        dao = _getAddress(_addressKey(Keys.DAO));

        address impl = address(new FeeRouter(addressProvider_));
        beacon = new UpgradeableBeacon(impl, constitutionalTimelock);
    }

    /**
     * @notice Deploys a BeaconProxy FeeRouter for `playerId` and initializes per-market state.
     * @param playerId Player identity associated with the FeeRouter.
     * @param atFunding Optional ATFunding for the 11% fee share (zero = 100% PBR until set).
     * @param pbrFeeHub League `PbrFeeHub` for the 89% PBR share (zero = unsupported even-split).
     * @return feeRouter Address of the newly deployed BeaconProxy.
     */
    function create(bytes32 playerId, address atFunding, address pbrFeeHub) external returns (address feeRouter) {
        if (playerId == bytes32(0)) revert Errors.ZeroId();

        bytes memory initData = abi.encodeCall(FeeRouter.initialize, (playerId, atFunding, pbrFeeHub));

        feeRouter = address(new BeaconProxy(address(beacon), initData));

        emit Events.FeeRouterCreated(playerId, feeRouter, pbrFeeHub, atFunding);
    }

    /// @notice Current FeeRouter implementation pointed to by the shared beacon
    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
