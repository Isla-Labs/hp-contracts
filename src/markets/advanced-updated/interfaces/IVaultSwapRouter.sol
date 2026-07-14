// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IVaultSwapRouter
 * @notice Minimal swap surface used by AdvancedTradeVault. Implemented by `HPSwapRouter`.
 * @dev Router pulls input tokens from the vault (via allowance) and returns output to the vault.
 */
interface IVaultSwapRouter {
    /// @notice Swap exact `amountIn` of `tokenIn` for at least `amountOutMin` of `tokenOut`.
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external returns (uint256 amountOut);

    /// @notice Swap at most `amountInMax` of `tokenIn` for exact `amountOut` of `tokenOut`.
    function swapExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 amountInMax,
        uint256 deadline
    ) external returns (uint256 amountIn);
}
