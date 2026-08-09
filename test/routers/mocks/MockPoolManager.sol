// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

import { IUnlockCallback } from "@v4-core/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDelta, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

/**
 * @notice Behavioral PoolManager stand-in for TradeRouter tests (1:1 exact-in swaps).
 * @dev Invokes `beforeSwap` / `afterSwap` on `key.hooks` when non-zero (test-double hooks only;
 *      real Doppler hooks require the canonical PoolManager as `msg.sender`).
 */
contract MockPoolManager {
    using CurrencyLibrary for Currency;

    error ExactInOnly();
    error TransferFailed();
    error InvalidHookSelector();

    receive() external payable {}

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        bytes calldata hookData
    ) external returns (BalanceDelta delta) {
        if (params.amountSpecified >= 0) revert ExactInOnly();

        address hooksAddr = address(key.hooks);
        if (hooksAddr != address(0)) {
            (bytes4 beforeSel,,) = IHooks(hooksAddr).beforeSwap(msg.sender, key, params, hookData);
            if (beforeSel != IHooks.beforeSwap.selector) revert InvalidHookSelector();
        }

        uint256 amountIn = uint256(-params.amountSpecified);
        int128 amt = int128(int256(amountIn));
        if (params.zeroForOne) {
            delta = toBalanceDelta(-amt, amt);
        } else {
            delta = toBalanceDelta(amt, -amt);
        }

        if (hooksAddr != address(0)) {
            (bytes4 afterSel,) = IHooks(hooksAddr).afterSwap(msg.sender, key, params, delta, hookData);
            if (afterSel != IHooks.afterSwap.selector) revert InvalidHookSelector();
        }
    }

    function sync(Currency) external pure {}

    function settle() external payable returns (uint256) {
        return msg.value;
    }

    function take(Currency currency, address to, uint256 amount) external {
        if (currency.isAddressZero()) {
            (bool ok,) = to.call{ value: amount }("");
            if (!ok) revert TransferFailed();
        } else {
            bool ok = IERC20(Currency.unwrap(currency)).transfer(to, amount);
            if (!ok) revert TransferFailed();
        }
    }
}
