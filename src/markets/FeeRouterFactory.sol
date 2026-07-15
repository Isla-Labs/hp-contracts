// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import { FeeRouter } from "./FeeRouter.sol";

/**
 * @title FeeRouterFactory
 * @notice Deploys per-market `BeaconProxy` FeeRouters sharing one `UpgradeableBeacon`.
 * @dev Beacon ownership (logic upgrades) is assigned to `multisig`. Each `create` call deploys a
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
    address public immutable multisig;

    /// @notice Emitted when a FeeRouter beacon proxy is deployed for a player
    event FeeRouterCreated(
        bytes32 indexed playerId,
        address indexed feeRouter,
        address indexed domesticPbrTreasury,
        address atFunding,
        address internationalPbrTreasury,
        bool isInternational,
        bool isActive
    );

    /// @notice Thrown when a required address is zero
    error ZeroAddress();

    /// @notice Thrown when a required id is zero
    error ZeroId();

    /**
     * @param lifecycleTimelock_ Address granted `LIFECYCLE_ROLE` on each FeeRouter.
     * @param multisig_ Address granted `ADMIN_ROLE` on each FeeRouter and ownership of the beacon.
     * @param tournamentRegistry_ TournamentRegistry baked into the FeeRouter implementation.
     */
    constructor(address lifecycleTimelock_, address multisig_, address tournamentRegistry_) {
        if (lifecycleTimelock_ == address(0) || multisig_ == address(0) || tournamentRegistry_ == address(0)) {
            revert ZeroAddress();
        }

        lifecycleTimelock = lifecycleTimelock_;
        multisig = multisig_;

        address impl = address(new FeeRouter(tournamentRegistry_));
        beacon = new UpgradeableBeacon(impl, multisig_);
    }

    /**
     * @notice Deploys a BeaconProxy FeeRouter for `playerId` and initializes per-market state.
     * @param playerId Player identity associated with the FeeRouter.
     * @param atFunding Optional FRTreasury for the 11% fee share (zero = 100% PBR until set).
     * @param domesticPbrTreasury Domestic PBRTreasury that receives the 89% fee share by default.
     * @param internationalPbrTreasury Optional international PBRTreasury (may be zero).
     * @param isInternational Whether PBR should route to the international treasury when set.
     * @param isActive Whether the player is active (false triggers even split across domestic treasuries).
     * @return feeRouter Address of the newly deployed BeaconProxy.
     */
    function create(
        bytes32 playerId,
        address atFunding,
        address domesticPbrTreasury,
        address internationalPbrTreasury,
        bool isInternational,
        bool isActive
    ) external returns (address feeRouter) {
        if (playerId == bytes32(0)) revert ZeroId();

        bytes memory initData = abi.encodeCall(
            FeeRouter.initialize,
            (
                lifecycleTimelock,
                multisig,
                playerId,
                atFunding,
                domesticPbrTreasury,
                internationalPbrTreasury,
                isInternational,
                isActive
            )
        );

        feeRouter = address(new BeaconProxy(address(beacon), initData));

        emit FeeRouterCreated(
            playerId, feeRouter, domesticPbrTreasury, atFunding, internationalPbrTreasury, isInternational, isActive
        );
    }

    /// @notice Current FeeRouter implementation pointed to by the shared beacon
    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
