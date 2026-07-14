// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title ILiquiditySource
 * @notice USD-denominated pool liquidity for FundingController gap inputs (pool reserves only).
 */
interface ILiquiditySource {
    /// @notice Live pool liquidity for `playerToken`, in USD 1e18 units (vault inventory/escrow excluded).
    function liquidityUsd(address playerToken) external view returns (uint256);
}
