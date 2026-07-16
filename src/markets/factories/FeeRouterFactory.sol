// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import { FeeRouter } from "@markets/FeeRouter.sol";

/**
 * @title FeeRouterFactory
 * @notice Deploys per-market `BeaconProxy` FeeRouters sharing one `UpgradeableBeacon`.
 * @dev Beacon ownership (logic upgrades) is assigned to `admin`. Each `create` call deploys a
 *      thin proxy with player-specific storage initialized via `FeeRouter.initialize`.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract FeeRouterFactory {
    /// @notice Shared beacon; upgrade to change logic for every market FeeRouter
    UpgradeableBeacon public immutable beacon;

    /// @notice Granted `LIFECYCLE_ROLE` on every deployed FeeRouter
    address public immutable lifecycleTimelock;

    /// @notice Granted `ADMIN_ROLE` on every deployed FeeRouter; also owns the beacon
    address public immutable admin;

    /// @notice Emitted when a FeeRouter beacon proxy is deployed for a player
    event FeeRouterCreated(
        bytes32 indexed playerId, address indexed feeRouter, address indexed pbrFeeHub, address atFunding
    );

    /// @notice Thrown when a required address is zero
    error ZeroAddress();

    /// @notice Thrown when a required id is zero
    error ZeroId();

    /**
     * @param lifecycleTimelock_ Address granted `LIFECYCLE_ROLE` on each FeeRouter.
     * @param admin_ Address granted `ADMIN_ROLE` on each FeeRouter and ownership of the beacon.
     * @param tournamentRegistry_ TournamentRegistry baked into the FeeRouter implementation.
     */
    constructor(address lifecycleTimelock_, address admin_, address tournamentRegistry_) {
        if (lifecycleTimelock_ == address(0) || admin_ == address(0) || tournamentRegistry_ == address(0)) {
            revert ZeroAddress();
        }

        lifecycleTimelock = lifecycleTimelock_;
        admin = admin_;

        address impl = address(new FeeRouter(tournamentRegistry_));
        beacon = new UpgradeableBeacon(impl, admin_);
    }

    /**
     * @notice Deploys a BeaconProxy FeeRouter for `playerId` and initializes per-market state.
     * @param playerId Player identity associated with the FeeRouter.
     * @param atFunding Optional ATFunding for the 11% fee share (zero = 100% PBR until set).
     * @param pbrFeeHub League `PbrFeeHub` for the 89% PBR share (zero = unsupported even-split).
     * @return feeRouter Address of the newly deployed BeaconProxy.
     */
    function create(bytes32 playerId, address atFunding, address pbrFeeHub) external returns (address feeRouter) {
        if (playerId == bytes32(0)) revert ZeroId();

        bytes memory initData =
            abi.encodeCall(FeeRouter.initialize, (lifecycleTimelock, admin, playerId, atFunding, pbrFeeHub));

        feeRouter = address(new BeaconProxy(address(beacon), initData));

        emit FeeRouterCreated(playerId, feeRouter, pbrFeeHub, atFunding);
    }

    /// @notice Current FeeRouter implementation pointed to by the shared beacon
    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
