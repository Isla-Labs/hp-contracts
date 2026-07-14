// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

/**
 * @title IPoolQuoter
 * @notice Minimal view-quoter surface (compatible with whetstone view-quoter-v4 `Quoter`).
 * @dev Local interface avoids pragma lock to the quoter package's `=0.8.26`.
 */
interface IPoolQuoter {
    function quoteSingle(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        external
        view
        returns (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32 initializedTicksCrossed);
}
