// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { AssetRegistry } from "../../../AssetRegistry.sol";
import { IMarkSource } from "../interfaces/IMarkSource.sol";
import { PoolPricing } from "./libraries/PoolPricing.sol";

/**
 * @title PoolMarkSource
 * @notice Per-market mark reader: V4 mid price as numeraire wei per 1e18 player tokens.
 * @dev Deploy one instance per market (bound `playerToken`). Vault EMA wraps this spot.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PoolMarkSource is IMarkSource {
    AssetRegistry public immutable registry;
    IPoolManager public immutable poolManager;
    address public immutable playerToken;

    constructor(AssetRegistry registry_, IPoolManager poolManager_, address playerToken_) {
        if (address(registry_) == address(0) || address(poolManager_) == address(0) || playerToken_ == address(0)) {
            revert PoolPricing.ZeroAddress();
        }
        registry = registry_;
        poolManager = poolManager_;
        playerToken = playerToken_;
    }

    /// @inheritdoc IMarkSource
    function spotPriceWad() external view override returns (uint256) {
        PoolKey memory key = PoolPricing.poolKey(registry, playerToken);
        return PoolPricing.spotPriceWad(poolManager, key, playerToken);
    }
}
