// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import { MarketsErrors as Errors } from "@base/global/libraries/errors/MarketsErrors.sol";
import { MarketsEvents as Events } from "@base/global/libraries/events/MarketsEvents.sol";
import { FeeRouter } from "@markets/FeeRouter.sol";

/**
 * @title FeeRouterFactory
 * @notice Deploys per-market `BeaconProxy` FeeRouters sharing one `UpgradeableBeacon`.
 * @dev Beacon ownership (logic upgrades) is assigned to `ConstitutionalTimelock`. Each `create`
 *      call deploys a thin proxy with player-specific storage via `FeeRouter.initialize`.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract FeeRouterFactory {
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
     * @param automator_ `Automator` — cat-3 on each FeeRouter.
     * @param maintenanceTimelock_ `MaintenanceTimelock` — cat-2 on each FeeRouter.
     * @param constitutionalTimelock_ `ConstitutionalTimelock` — cat-1 + beacon owner.
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE` on each FeeRouter.
     * @param tournamentRegistry_ TournamentRegistry baked into the FeeRouter implementation.
     */
    constructor(
        address automator_,
        address maintenanceTimelock_,
        address constitutionalTimelock_,
        address dao_,
        address tournamentRegistry_
    ) {
        if (
            automator_ == address(0) || maintenanceTimelock_ == address(0) || constitutionalTimelock_ == address(0)
                || dao_ == address(0) || tournamentRegistry_ == address(0)
        ) revert Errors.ZeroAddress();

        automator = automator_;
        maintenanceTimelock = maintenanceTimelock_;
        constitutionalTimelock = constitutionalTimelock_;
        dao = dao_;

        address impl = address(new FeeRouter(tournamentRegistry_));
        beacon = new UpgradeableBeacon(impl, constitutionalTimelock_);
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

        bytes memory initData = abi.encodeCall(
            FeeRouter.initialize,
            (automator, maintenanceTimelock, constitutionalTimelock, dao, playerId, atFunding, pbrFeeHub)
        );

        feeRouter = address(new BeaconProxy(address(beacon), initData));

        emit Events.FeeRouterCreated(playerId, feeRouter, pbrFeeHub, atFunding);
    }

    /// @notice Current FeeRouter implementation pointed to by the shared beacon
    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
