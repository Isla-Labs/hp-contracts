// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/access/Ownable2Step.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { AssetRegistry } from "../../../AssetRegistry.sol";
import { ILiquiditySource } from "../interfaces/ILiquiditySource.sol";
import { PoolPricing } from "./libraries/PoolPricing.sol";

/**
 * @title PoolLiquiditySource
 * @notice Singleton USD liquidity reader from V4 in-range virtual reserves (pool only; vault excluded).
 * @dev Stable numeraires (e.g. USDC) are scaled to 1e18 USD 1:1. Native ETH uses `ethUsdWad` (governed).
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PoolLiquiditySource is ILiquiditySource, Ownable2Step {
    AssetRegistry public immutable registry;
    IPoolManager public immutable poolManager;

    /// @notice USD WAD per 1e18 ETH when numeraire is native. Ignored for ERC20 stables.
    uint256 public ethUsdWad;

    event EthUsdUpdated(uint256 ethUsdWad);

    constructor(address initialOwner, AssetRegistry registry_, IPoolManager poolManager_, uint256 ethUsdWad_)
        Ownable(initialOwner)
    {
        if (
            initialOwner == address(0) || address(registry_) == address(0) || address(poolManager_) == address(0)
        ) {
            revert PoolPricing.ZeroAddress();
        }
        registry = registry_;
        poolManager = poolManager_;
        ethUsdWad = ethUsdWad_;
    }

    /// @inheritdoc ILiquiditySource
    function liquidityUsd(address playerToken) external view override returns (uint256) {
        PoolKey memory key = PoolPricing.poolKey(registry, playerToken);
        return PoolPricing.liquidityUsdWad(poolManager, key, playerToken, ethUsdWad);
    }

    function setEthUsdWad(uint256 ethUsdWad_) external onlyOwner {
        ethUsdWad = ethUsdWad_;
        emit EthUsdUpdated(ethUsdWad_);
    }
}
