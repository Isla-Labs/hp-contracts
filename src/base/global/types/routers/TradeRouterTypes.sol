// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PoolKey } from "@v4-core/types/PoolKey.sol";

/**
 * @title TradeRouterTypes
 * @notice V4 unlock callback payload for `TradeRouter`.
 */

/// @notice Exact-in swap args decoded inside `unlockCallback`.
struct UnlockData {
    PoolKey key;
    bool zeroForOne;
    uint256 amountIn;
    address recipient;
}
