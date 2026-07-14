// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IERC20Metadata } from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { FixedPoint96 } from "@v4-core/libraries/FixedPoint96.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { Currency } from "@v4-core/types/Currency.sol";

import { AssetData } from "@base/global/types/AssetTypes.sol";
import { AssetRegistry } from "../../../../AssetRegistry.sol";

/**
 * @title PoolPricing
 * @notice Shared V4 pool lookups for AdvancedTrade thin readers (mark / liq / impact).
 */
library PoolPricing {
    using StateLibrary for IPoolManager;

    error ZeroAddress();
    error PoolNotSet();
    error PlayerNotInPool();
    error InvalidSqrtPrice();

    uint256 internal constant WAD = 1e18;

    /// @dev Exposed for sibling readers (libraries cannot export internal constants to other files).
    function wad() internal pure returns (uint256) {
        return WAD;
    }

    function poolKey(AssetRegistry registry, address playerToken) internal view returns (PoolKey memory key) {
        if (address(registry) == address(0) || playerToken == address(0)) revert ZeroAddress();
        AssetData memory data = registry.getAssetData(playerToken);
        key = data.registryData.spotMarketData.activePool;
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 == address(0) && c1 == address(0)) revert PoolNotSet();
        if (playerToken != c0 && playerToken != c1) revert PlayerNotInPool();
    }

    function isPlayerToken0(PoolKey memory key, address playerToken) internal pure returns (bool) {
        return Currency.unwrap(key.currency0) == playerToken;
    }

    function numeraire(PoolKey memory key, address playerToken) internal pure returns (address) {
        return isPlayerToken0(key, playerToken) ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
    }

    /// @notice Collateral (numeraire) wei per 1e18 player tokens, for vault mark math.
    function spotPriceWad(IPoolManager manager, PoolKey memory key, address playerToken)
        internal
        view
        returns (uint256)
    {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert InvalidSqrtPrice();

        bool playerIs0 = isPlayerToken0(key, playerToken);
        // token1 per token0 in raw wei: mulDiv(1e18, sqrt^2, 2^192) via two steps
        if (playerIs0) {
            // numeraire is token1 per 1e18 player(token0)
            uint256 num = FullMath.mulDiv(WAD, sqrtPriceX96, FixedPoint96.Q96);
            return FullMath.mulDiv(num, sqrtPriceX96, FixedPoint96.Q96);
        } else {
            // numeraire is token0 per 1e18 player(token1)
            uint256 num = FullMath.mulDiv(WAD, FixedPoint96.Q96, sqrtPriceX96);
            return FullMath.mulDiv(num, FixedPoint96.Q96, sqrtPriceX96);
        }
    }

    /// @notice Virtual reserves implied by in-range liquidity at the current price.
    function virtualReserves(IPoolManager manager, PoolKey memory key)
        internal
        view
        returns (uint256 amount0, uint256 amount1, uint160 sqrtPriceX96)
    {
        PoolId id = key.toId();
        (sqrtPriceX96,,,) = manager.getSlot0(id);
        if (sqrtPriceX96 == 0) revert InvalidSqrtPrice();
        uint128 liquidity = manager.getLiquidity(id);
        amount0 = FullMath.mulDiv(uint256(liquidity), FixedPoint96.Q96, sqrtPriceX96);
        amount1 = FullMath.mulDiv(uint256(liquidity), sqrtPriceX96, FixedPoint96.Q96);
    }

    /// @notice Value virtual reserves in 1e18 USD units (1:1 for USDC-like numeraires after decimal scale).
    function liquidityUsdWad(IPoolManager manager, PoolKey memory key, address playerToken, uint256 ethUsdWad)
        internal
        view
        returns (uint256)
    {
        (uint256 amount0, uint256 amount1,) = virtualReserves(manager, key);
        address num = numeraire(key, playerToken);
        bool playerIs0 = isPlayerToken0(key, playerToken);

        uint256 playerRaw = playerIs0 ? amount0 : amount1;
        uint256 numRaw = playerIs0 ? amount1 : amount0;
        uint256 price = spotPriceWad(manager, key, playerToken); // numeraire wei per 1e18 player

        // player side in numeraire wei
        uint256 playerInNumeraire = FullMath.mulDiv(playerRaw, price, WAD);
        uint256 totalNumeraireWei = playerInNumeraire + numRaw;

        return _toUsdWad(num, totalNumeraireWei, ethUsdWad);
    }

    function _toUsdWad(address numeraireToken, uint256 amountWei, uint256 ethUsdWad) private view returns (uint256) {
        if (numeraireToken == address(0)) {
            // native ETH: amountWei is 1e18-based; multiply by ETH/USD WAD
            if (ethUsdWad == 0) revert InvalidSqrtPrice();
            return FullMath.mulDiv(amountWei, ethUsdWad, WAD);
        }
        uint8 decimals = IERC20Metadata(numeraireToken).decimals();
        if (decimals == 18) {
            // Assume 1:1 USD stable (USDC.e 18-dec mocks) or ethUsd unused
            return amountWei;
        }
        if (decimals < 18) {
            return amountWei * (10 ** (18 - decimals));
        }
        return amountWei / (10 ** (decimals - 18));
    }

    function buyPlayerExactOutParams(PoolKey memory key, address playerToken, uint256 size)
        internal
        pure
        returns (IPoolManager.SwapParams memory params)
    {
        bool playerIs0 = isPlayerToken0(key, playerToken);
        // Exact out of player token: positive amountSpecified
        // Player is token0 → buy token0 → zeroForOne = false (1→0)
        // Player is token1 → buy token1 → zeroForOne = true (0→1)
        bool zeroForOne = !playerIs0;
        params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(size),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }
}
