// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { RoutersErrors as Errors } from "@errors/routers/RoutersErrors.sol";
import { RoutersEvents as Events } from "@events/routers/RoutersEvents.sol";
import { DopplerData } from "@types/registries/PlayerSetTypes.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";

import { IUnlockCallback } from "@v4-core/interfaces/callback/IUnlockCallback.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";

/**
 * @title TradeRouter
 * @notice PSR lookup + ETH↔playerToken V4 swaps; optional zRouter calldata for ERC20↔ETH wings.
 * @dev Player-token leg always uses `DopplerData.activePool` (never zRouter discovery).
 *      For `buyWithToken` / `sellToToken`, encode zRouter calls with:
 *      - `to = address(this)` on the buy wing (ETH out to this router), then player buy
 *      - `to = msg.sender` on the sell wing (ERC20 out to user), with ETH in from this router
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TradeRouter is AddressBook, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    struct UnlockData {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        address recipient;
    }

    /// @param addressProvider_ Protocol `AddressProvider` (`PLAYER_SET_REGISTRY`, `Z_ROUTER`).
    /// @param poolManager_ Uniswap v4 `PoolManager` for this deployment.
    constructor(address addressProvider_, address poolManager_) AddressBook(addressProvider_) {
        if (poolManager_ == address(0)) revert Errors.ZeroAddress();
        poolManager = IPoolManager(poolManager_);
    }

    receive() external payable {}

    // --------------------------------------------
    //  ETH ↔ playerToken
    // --------------------------------------------

    /// @notice Exact-in buy: spend `msg.value` ETH for `playerToken` (PSR active pool).
    function buy(
        address playerToken,
        uint256 minAmountOut,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Errors.Expired();
        if (msg.value == 0) revert Errors.ZeroAmount();

        amountOut = _swapExactInEthForPlayer(playerToken, msg.value, msg.sender);
        if (amountOut < minAmountOut) revert Errors.Slippage();

        emit Events.Bought(msg.sender, playerToken, msg.value, amountOut);
    }

    /// @notice Exact-in sell: spend `amountIn` playerToken for ETH paid to `msg.sender`.
    function sell(
        address playerToken,
        uint256 amountIn,
        uint256 minEthOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 ethOut) {
        if (block.timestamp > deadline) revert Errors.Expired();
        if (amountIn == 0) revert Errors.ZeroAmount();

        IERC20(playerToken).safeTransferFrom(msg.sender, address(this), amountIn);
        ethOut = _swapExactInPlayerForEth(playerToken, amountIn, msg.sender);
        if (ethOut < minEthOut) revert Errors.Slippage();

        emit Events.Sold(msg.sender, playerToken, amountIn, ethOut);
    }

    // --------------------------------------------
    //  ERC20 ↔ ETH (zRouter) + player leg
    // --------------------------------------------

    /**
     * @notice Pull `inputToken`, run opaque zRouter calldata to ETH on this router, then buy playerToken.
     * @dev `zRouterCall` must send ETH to `address(this)`. `msg.value` must be 0.
     *      If `inputToken == address(0)`, use `buy` instead.
     */
    function buyWithToken(
        address playerToken,
        address inputToken,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bytes calldata zRouterCall
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Errors.Expired();
        if (amountIn == 0) revert Errors.ZeroAmount();
        if (msg.value != 0) revert Errors.InvalidMsgValue();
        if (inputToken == address(0) || inputToken == playerToken) revert Errors.InvalidPath();
        if (zRouterCall.length == 0) revert Errors.InvalidPath();

        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), amountIn);

        address zRouter = _zRouter();
        IERC20(inputToken).forceApprove(zRouter, amountIn);

        uint256 ethBefore = address(this).balance;
        _callZRouter(zRouter, zRouterCall, 0);
        IERC20(inputToken).forceApprove(zRouter, 0);

        uint256 ethIn = address(this).balance - ethBefore;
        if (ethIn == 0) revert Errors.ZeroAmount();

        amountOut = _swapExactInEthForPlayer(playerToken, ethIn, msg.sender);
        if (amountOut < minAmountOut) revert Errors.Slippage();

        emit Events.Bought(msg.sender, playerToken, ethIn, amountOut);
    }

    /**
     * @notice Sell playerToken to ETH on this router, then run opaque zRouter calldata to `outputToken`.
     * @dev `zRouterCall` should spend the ETH held here and send `outputToken` to `msg.sender`.
     */
    function sellToToken(
        address playerToken,
        address outputToken,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bytes calldata zRouterCall
    ) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Errors.Expired();
        if (amountIn == 0) revert Errors.ZeroAmount();
        if (outputToken == address(0) || outputToken == playerToken) revert Errors.InvalidPath();
        if (zRouterCall.length == 0) revert Errors.InvalidPath();

        IERC20(playerToken).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 ethOut = _swapExactInPlayerForEth(playerToken, amountIn, address(this));
        if (ethOut == 0) revert Errors.ZeroAmount();

        uint256 outBefore = IERC20(outputToken).balanceOf(msg.sender);
        _callZRouter(_zRouter(), zRouterCall, ethOut);
        amountOut = IERC20(outputToken).balanceOf(msg.sender) - outBefore;
        if (amountOut < minAmountOut) revert Errors.Slippage();

        // Refund any unused ETH from a partial zRouter spend.
        uint256 dust = address(this).balance;
        if (dust != 0) _transferEth(msg.sender, dust);

        emit Events.Sold(msg.sender, playerToken, amountIn, ethOut);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @notice Resolve the player's active Doppler `PoolKey` (reverts if not ETH↔token).
    function poolOf(address playerToken) external view returns (PoolKey memory key) {
        (key,) = _poolOf(playerToken);
    }

    // --------------------------------------------
    //  V4 unlock
    // --------------------------------------------

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Errors.Unauthorized();

        UnlockData memory data = abi.decode(rawData, (UnlockData));
        int256 amountSpecified = -int256(data.amountIn);

        BalanceDelta delta = poolManager.swap(
            data.key,
            IPoolManager.SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: data.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        (Currency inCurrency, Currency outCurrency, uint256 amountOut) =
            _decodeExactIn(data.key, data.zeroForOne, delta);

        _settle(inCurrency, data.amountIn);
        poolManager.take(outCurrency, data.recipient, amountOut);

        return abi.encode(amountOut);
    }

    // --------------------------------------------
    //  Internal — player pool
    // --------------------------------------------

    function _swapExactInEthForPlayer(
        address playerToken,
        uint256 ethIn,
        address recipient
    ) internal returns (uint256 amountOut) {
        (PoolKey memory key, bool assetIsCurrency1) = _poolOf(playerToken);
        // ETH → asset: zeroForOne iff ETH is currency0 (asset is currency1).
        bool zeroForOne = assetIsCurrency1;
        amountOut = abi.decode(
            poolManager.unlock(
                abi.encode(
                    UnlockData({ key: key, zeroForOne: zeroForOne, amountIn: ethIn, recipient: recipient })
                )
            ),
            (uint256)
        );
    }

    function _swapExactInPlayerForEth(
        address playerToken,
        uint256 amountIn,
        address recipient
    ) internal returns (uint256 ethOut) {
        (PoolKey memory key, bool assetIsCurrency1) = _poolOf(playerToken);
        // Asset → ETH: zeroForOne iff asset is currency0.
        bool zeroForOne = !assetIsCurrency1;
        ethOut = abi.decode(
            poolManager.unlock(
                abi.encode(
                    UnlockData({ key: key, zeroForOne: zeroForOne, amountIn: amountIn, recipient: recipient })
                )
            ),
            (uint256)
        );
    }

    function _poolOf(address playerToken) internal view returns (PoolKey memory key, bool assetIsCurrency1) {
        if (playerToken == address(0)) revert Errors.ZeroAddress();

        IPlayerSetRegistry psr = IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));
        bytes32 playerId = psr.playerIdOfToken(playerToken);
        if (playerId == bytes32(0)) revert Errors.UnknownToken(playerToken);

        DopplerData memory doppler = psr.getDopplerData(playerId);
        key = doppler.activePool;

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);

        if (c0 == address(0) && c1 == playerToken) {
            assetIsCurrency1 = true;
            return (key, assetIsCurrency1);
        }
        if (c1 == address(0) && c0 == playerToken) {
            assetIsCurrency1 = false;
            return (key, assetIsCurrency1);
        }
        revert Errors.InvalidPool(playerToken);
    }

    function _decodeExactIn(
        PoolKey memory key,
        bool zeroForOne,
        BalanceDelta delta
    ) internal pure returns (Currency inCurrency, Currency outCurrency, uint256 amountOut) {
        if (zeroForOne) {
            inCurrency = key.currency0;
            outCurrency = key.currency1;
            int128 out = delta.amount1();
            if (out <= 0) revert Errors.Slippage();
            amountOut = uint256(uint128(out));
        } else {
            inCurrency = key.currency1;
            outCurrency = key.currency0;
            int128 out = delta.amount0();
            if (out <= 0) revert Errors.Slippage();
            amountOut = uint256(uint128(out));
        }
    }

    function _settle(Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) {
            poolManager.settle{ value: amount }();
        } else {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    // --------------------------------------------
    //  Internal — zRouter / ETH
    // --------------------------------------------

    function _zRouter() internal view returns (address) {
        return _getAddress(_addressKey(Addresses.Z_ROUTER));
    }

    function _callZRouter(address zRouter, bytes calldata data, uint256 value) internal {
        (bool ok, bytes memory ret) = zRouter.call{ value: value }(data);
        if (!ok) {
            if (ret.length > 0) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            revert Errors.ZRouterCallFailed();
        }
    }

    function _transferEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert Errors.EthTransferFailed();
    }
}
