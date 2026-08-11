// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Thin SDK-facing facade over `ZQuoterBase` for Base Sepolia.
///      Matches the `zamm` SDK ABI surface used by `buildBestSwapViaETHMulticall` /
///      `getQuotes` / `buildBestSwap`. `buildSplitSwap` / `quoteCurve` are no-ops
///      (SDK treats those as optional via Promise.allSettled).

interface IZQuoterBaseCore {
    struct Quote {
        uint8 source;
        uint256 feeBps;
        uint256 amountIn;
        uint256 amountOut;
    }

    function getQuotes(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount
    ) external view returns (Quote memory best, Quote[] memory quotes);

    function buildBestSwap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    ) external view returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue);

    function buildBestSwapViaETHMulticall(
        address to,
        address refundTo,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    ) external view returns (Quote memory a, Quote memory b, bytes[] memory calls, uint256 msgValue);
}

contract ZQuoter {
    enum AMM {
        UNI_V2,
        SUSHI,
        ZAMM,
        UNI_V3,
        UNI_V4,
        CURVE,
        LIDO,
        WETH_WRAP,
        V4_HOOKED
    }

    struct Quote {
        AMM source;
        uint256 feeBps;
        uint256 amountIn;
        uint256 amountOut;
    }

    IZQuoterBaseCore public immutable BASE;
    address public immutable ZROUTER;

    constructor(address base_, address zRouter_) payable {
        require(base_ != address(0) && zRouter_ != address(0), "ZERO");
        BASE = IZQuoterBaseCore(base_);
        ZROUTER = zRouter_;
    }

    function getQuotes(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount
    ) public view returns (Quote memory best, Quote[] memory quotes) {
        (bool ok, bytes memory ret) = address(BASE)
            .staticcall(
                abi.encodeWithSelector(IZQuoterBaseCore.getQuotes.selector, exactOut, tokenIn, tokenOut, swapAmount)
            );
        require(ok, "getQuotes");
        (best, quotes) = abi.decode(ret, (Quote, Quote[]));
    }

    function buildBestSwap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    ) public view returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) {
        (bool ok, bytes memory ret) = address(BASE)
            .staticcall(
                abi.encodeWithSelector(
                    IZQuoterBaseCore.buildBestSwap.selector,
                    to,
                    exactOut,
                    tokenIn,
                    tokenOut,
                    swapAmount,
                    slippageBps,
                    deadline
                )
            );
        require(ok, "buildBestSwap");
        (best, callData, amountLimit, msgValue) = abi.decode(ret, (Quote, bytes, uint256, uint256));
    }

    /// @notice SDK entry: same args as zamm `ZQUOTER_ABI`, returns encoded `multicall` bytes.
    function buildBestSwapViaETHMulticall(
        address to,
        address refundTo,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    )
        public
        view
        returns (Quote memory a, Quote memory b, bytes[] memory calls, bytes memory multicall, uint256 msgValue)
    {
        (bool ok, bytes memory ret) = address(BASE)
            .staticcall(
                abi.encodeWithSelector(
                    IZQuoterBaseCore.buildBestSwapViaETHMulticall.selector,
                    to,
                    refundTo,
                    exactOut,
                    tokenIn,
                    tokenOut,
                    swapAmount,
                    slippageBps,
                    deadline
                )
            );
        require(ok, "buildBestSwapViaETHMulticall");
        (a, b, calls, msgValue) = abi.decode(ret, (Quote, Quote, bytes[], uint256));
        multicall = abi.encodeWithSelector(bytes4(keccak256("multicall(bytes[])")), calls);
    }

    /// @dev Optional SDK path — not implemented on Sepolia (no Curve / split router).
    function buildSplitSwap(
        address,
        address,
        address,
        uint256,
        uint256,
        uint256
    ) external pure returns (Quote[2] memory legs, bytes memory multicall, uint256 msgValue) {
        legs[0] = Quote(AMM.UNI_V2, 0, 0, 0);
        legs[1] = Quote(AMM.UNI_V2, 0, 0, 0);
        multicall = "";
        msgValue = 0;
    }

    /// @dev Optional SDK path — Curve is not deployed on Base Sepolia.
    function quoteCurve(
        bool,
        address,
        address,
        uint256,
        uint256
    )
        external
        pure
        returns (
            uint256 amountIn,
            uint256 amountOut,
            address bestPool,
            bool usedUnderlying,
            bool usedStable,
            uint8 iIndex,
            uint8 jIndex
        )
    {
        return (0, 0, address(0), false, false, 0, 0);
    }
}
