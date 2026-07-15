// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { FeeRouter } from "./FeeRouter.sol";

/**
 * @title FeeRouterFactory
 * @notice Deploys per-market FeeRouter instances owned by LifecycleTimelock.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract FeeRouterFactory {
    /// @notice Owner set on every deployed FeeRouter
    address public immutable lifecycleTimelock;

    /// @notice TournamentRegistry passed to every deployed FeeRouter
    address public immutable tournamentRegistry;

    /// @notice Emitted when a FeeRouter is deployed for a player
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
     * @param lifecycleTimelock_ Address passed as `initialOwner` to each FeeRouter.
     * @param tournamentRegistry_ TournamentRegistry used for inactive OOF fee splits.
     */
    constructor(address lifecycleTimelock_, address tournamentRegistry_) {
        if (lifecycleTimelock_ == address(0) || tournamentRegistry_ == address(0)) revert ZeroAddress();
        lifecycleTimelock = lifecycleTimelock_;
        tournamentRegistry = tournamentRegistry_;
    }

    /**
     * @notice Deploys a FeeRouter for `playerId` with LifecycleTimelock as owner.
     * @param playerId Player identity associated with the FeeRouter.
     * @param atFunding FRTreasury that receives the 11% fee share.
     * @param domesticPbrTreasury Domestic PBRTreasury that receives the 89% fee share by default.
     * @param internationalPbrTreasury Optional international PBRTreasury (may be zero).
     * @param isInternational Whether PBR should route to the international treasury when set.
     * @param isActive Whether the player is active (false triggers even split across domestic treasuries).
     * @return feeRouter Address of the newly deployed FeeRouter.
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

        feeRouter = address(
            new FeeRouter(
                lifecycleTimelock,
                playerId,
                atFunding,
                tournamentRegistry,
                domesticPbrTreasury,
                internationalPbrTreasury,
                isInternational,
                isActive
            )
        );

        emit FeeRouterCreated(
            playerId, feeRouter, domesticPbrTreasury, atFunding, internationalPbrTreasury, isInternational, isActive
        );
    }
}
