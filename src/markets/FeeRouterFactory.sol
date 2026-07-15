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

    /// @notice Emitted when a FeeRouter is deployed for a market
    event FeeRouterCreated(
        address indexed market, address indexed feeRouter, address indexed pbrTreasury, address atFunding
    );

    /// @notice Thrown when a required address is zero
    error ZeroAddress();

    /**
     * @param lifecycleTimelock_ Address passed as `initialOwner` to each FeeRouter.
     */
    constructor(address lifecycleTimelock_) {
        if (lifecycleTimelock_ == address(0)) revert ZeroAddress();
        lifecycleTimelock = lifecycleTimelock_;
    }

    /**
     * @notice Deploys a FeeRouter for `market` with LifecycleTimelock as owner.
     * @param market Market / asset token associated with the FeeRouter.
     * @param atFunding FRTreasury that receives the 11% fee share.
     * @param pbrTreasury PBRTreasury that receives the 89% fee share.
     * @return feeRouter Address of the newly deployed FeeRouter.
     */
    function create(address market, address atFunding, address pbrTreasury) external returns (address feeRouter) {
        feeRouter = address(new FeeRouter(lifecycleTimelock, market, atFunding, pbrTreasury));
        emit FeeRouterCreated(market, feeRouter, pbrTreasury, atFunding);
    }
}
