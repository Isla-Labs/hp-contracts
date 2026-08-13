// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PoolId } from "@v4-core/types/PoolId.sol";

/**
 * @title IRehypePoolInfo
 * @notice Narrow Rehype bonding-hook pool info view (avoids Quoter solc pin).
 */
interface IRehypePoolInfo {
    function getPoolInfo(PoolId poolId) external view returns (address asset, address numeraire, address buybackDst);
}
