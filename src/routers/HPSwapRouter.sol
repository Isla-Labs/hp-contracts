// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@v4-core/interfaces/callback/IUnlockCallback.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { TransientStateLibrary } from "@v4-core/libraries/TransientStateLibrary.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { AssetRegistry } from "../AssetRegistry.sol";
import { AssetData } from "../base/global/types/AssetTypes.sol";
import { IVaultSwapRouter } from "../markets/advanced-updated/interfaces/IVaultSwapRouter.sol";
import { PoolPricing } from "../markets/advanced-updated/oracles/libraries/PoolPricing.sol";

/**
 * @title HPSwapRouter
 * @notice V4 pool swap adapter for AdvancedTradeVault (`IVaultSwapRouter`).
 * @dev Resolves `PoolKey` from `AssetRegistry` for the player-token leg of the pair, then
 *      unlocks the PoolManager to swap. Caller (vault) must approve this router for `tokenIn`.
 *      Output is returned to the caller. Native ETH pairs are not supported in this wireframe.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract HPSwapRouter is IVaultSwapRouter, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    AssetRegistry public immutable registry;
    IPoolManager public immutable poolManager;

    error ZeroAddress();
    error DeadlineExpired();
    error SlippageExceeded();
    error InvalidPair();
    error NativeNotSupported();
    error NotPoolManager();
    error ZeroAmount();

    struct CallbackData {
        address payer;
        address recipient;
        PoolKey key;
        IPoolManager.SwapParams params;
        bool isExactIn;
        uint256 limit; // amountOutMin (exact-in) or amountInMax (exact-out)
    }

    constructor(AssetRegistry registry_, IPoolManager poolManager_) {
        if (address(registry_) == address(0) || address(poolManager_) == address(0)) revert ZeroAddress();
        registry = registry_;
        poolManager = poolManager_;
    }

    /// @inheritdoc IVaultSwapRouter
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external override nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (deadline == 0 || block.timestamp > deadline) revert DeadlineExpired();

        PoolKey memory key = _poolKeyForPair(tokenIn, tokenOut);
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;

        bytes memory result = poolManager.unlock(
            abi.encode(
                CallbackData({
                    payer: msg.sender,
                    recipient: msg.sender,
                    key: key,
                    params: IPoolManager.SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: -int256(amountIn),
                        sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    }),
                    isExactIn: true,
                    limit: amountOutMin
                })
            )
        );
        amountOut = abi.decode(result, (uint256));
    }

    /// @inheritdoc IVaultSwapRouter
    function swapExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 amountInMax,
        uint256 deadline
    ) external override nonReentrant returns (uint256 amountIn) {
        if (amountOut == 0) revert ZeroAmount();
        if (deadline == 0 || block.timestamp > deadline) revert DeadlineExpired();

        PoolKey memory key = _poolKeyForPair(tokenIn, tokenOut);
        // Buying `tokenOut`: zeroForOne when tokenOut is currency1 (sell currency0).
        bool zeroForOne = Currency.unwrap(key.currency1) == tokenOut;

        bytes memory result = poolManager.unlock(
            abi.encode(
                CallbackData({
                    payer: msg.sender,
                    recipient: msg.sender,
                    key: key,
                    params: IPoolManager.SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: int256(amountOut),
                        sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    }),
                    isExactIn: false,
                    limit: amountInMax
                })
            )
        );
        amountIn = abi.decode(result, (uint256));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = poolManager.swap(data.key, data.params, "");

        int256 delta0 = poolManager.currencyDelta(address(this), data.key.currency0);
        int256 delta1 = poolManager.currencyDelta(address(this), data.key.currency1);

        // Pay debts (negative deltas), take credits (positive deltas).
        if (delta0 < 0) _settle(data.key.currency0, data.payer, uint256(-delta0));
        if (delta1 < 0) _settle(data.key.currency1, data.payer, uint256(-delta1));
        if (delta0 > 0) poolManager.take(data.key.currency0, data.recipient, uint256(delta0));
        if (delta1 > 0) poolManager.take(data.key.currency1, data.recipient, uint256(delta1));

        if (data.isExactIn) {
            uint256 amountOut = data.params.zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
            if (amountOut < data.limit) revert SlippageExceeded();
            return abi.encode(amountOut);
        } else {
            uint256 amountIn = data.params.zeroForOne ? uint256(int256(-delta.amount0())) : uint256(int256(-delta.amount1()));
            if (amountIn > data.limit) revert SlippageExceeded();
            return abi.encode(amountIn);
        }
    }

    /// @dev Prefer registered player-token pool; verify the other leg is the pair numeraire.
    function _poolKeyForPair(address tokenIn, address tokenOut) internal view returns (PoolKey memory key) {
        if (tokenIn == address(0) || tokenOut == address(0)) revert NativeNotSupported();
        if (tokenIn == tokenOut) revert InvalidPair();

        address player = _registeredPlayer(tokenIn);
        if (player == address(0)) player = _registeredPlayer(tokenOut);
        if (player == address(0)) revert InvalidPair();

        key = PoolPricing.poolKey(registry, player);
        address other = player == tokenIn ? tokenOut : tokenIn;
        address num = PoolPricing.numeraire(key, player);
        if (other != num) revert InvalidPair();
    }

    function _registeredPlayer(address token) internal view returns (address) {
        AssetData memory data = registry.getAssetData(token);
        if (data.token != token) return address(0);
        address c0 = Currency.unwrap(data.registryData.spotMarketData.activePool.currency0);
        address c1 = Currency.unwrap(data.registryData.spotMarketData.activePool.currency1);
        if (c0 == address(0) && c1 == address(0)) return address(0);
        return token;
    }

    function _settle(Currency currency, address payer, uint256 amount) internal {
        if (currency.isAddressZero()) revert NativeNotSupported();
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(poolManager), amount);
        poolManager.settle();
    }
}
