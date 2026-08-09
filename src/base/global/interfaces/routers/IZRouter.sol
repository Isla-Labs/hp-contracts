// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IZRouter
 * @notice Minimal surface of zRouter used by `TradeRouter` (opaque calldata also supported via `.call`).
 * @dev See https://github.com/z-fi/zRouter — `tokenIn`/`tokenOut` use `address(0)` for native ETH.
 */
interface IZRouter {
    function swapV2(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    function swapV3(
        address to,
        bool exactOut,
        uint24 swapFee,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    function swapV4(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
}
