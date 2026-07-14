// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { AssetRegistry } from "../../../AssetRegistry.sol";
import { IImpactEstimator } from "../interfaces/IImpactEstimator.sol";
import { IPoolQuoter } from "./interfaces/IPoolQuoter.sol";
import { PoolPricing } from "./libraries/PoolPricing.sol";

/**
 * @title PoolImpactEstimator
 * @notice Size-dependent close-impact via V4 view quoter (exact-out buy of player tokens).
 * @dev Impact = (execCost − midCost) / midCost in WAD, where midCost = size * spot / 1e18.
 *      Pass the deployed view-quoter-v4 `Quoter` address as `quoter_`.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PoolImpactEstimator is IImpactEstimator {
    AssetRegistry public immutable registry;
    IPoolManager public immutable poolManager;
    IPoolQuoter public immutable quoter;

    error ZeroSize();
    error QuoteFailed();

    constructor(AssetRegistry registry_, IPoolManager poolManager_, IPoolQuoter quoter_) {
        if (address(registry_) == address(0) || address(poolManager_) == address(0) || address(quoter_) == address(0))
        {
            revert PoolPricing.ZeroAddress();
        }
        registry = registry_;
        poolManager = poolManager_;
        quoter = quoter_;
    }

    /// @inheritdoc IImpactEstimator
    function estimateCloseImpactWad(address playerToken, uint256 size) external view override returns (uint256) {
        if (size == 0) revert ZeroSize();

        PoolKey memory key = PoolPricing.poolKey(registry, playerToken);
        uint256 mid = PoolPricing.spotPriceWad(poolManager, key, playerToken);
        uint256 midCost = (size * mid) / PoolPricing.wad();
        if (midCost == 0) revert PoolPricing.InvalidSqrtPrice();

        IPoolManager.SwapParams memory params = PoolPricing.buyPlayerExactOutParams(key, playerToken, size);
        (int256 amount0, int256 amount1,,) = quoter.quoteSingle(key, params);

        bool playerIs0 = PoolPricing.isPlayerToken0(key, playerToken);
        uint256 execCost = playerIs0 ? PoolPricing.abs(amount1) : PoolPricing.abs(amount0);
        if (execCost == 0) revert QuoteFailed();

        if (execCost <= midCost) return 0;
        return ((execCost - midCost) * PoolPricing.wad()) / midCost;
    }
}
