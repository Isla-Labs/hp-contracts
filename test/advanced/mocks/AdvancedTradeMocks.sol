// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { IVaultSwapRouter } from "../../../src/markets/advanced-updated/interfaces/IVaultSwapRouter.sol";
import { IMarkSource } from "../../../src/markets/advanced-updated/interfaces/IMarkSource.sol";

/// @dev Simple mintable ERC20 for tests (18 decimals).
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Fixed-price spot oracle (WAD collateral per 1e18 player token).
contract MockMarkSource is IMarkSource {
    uint256 public spot;

    constructor(uint256 spot_) {
        spot = spot_;
    }

    function setSpot(uint256 spot_) external {
        spot = spot_;
    }

    function spotPriceWad() external view returns (uint256) {
        return spot;
    }
}

/// @dev Constant-price swap router: 1 player token ↔ `priceWad` collateral (WAD math).
contract MockSwapRouter is IVaultSwapRouter {
    using SafeERC20 for IERC20;

    uint256 public priceWad; // collateral wei per 1e18 player token

    error Deadline();
    error Slippage();
    error ZeroPrice();

    constructor(uint256 priceWad_) {
        priceWad = priceWad_;
    }

    function setPrice(uint256 priceWad_) external {
        priceWad = priceWad_;
    }

    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Deadline();
        if (priceWad == 0) revert ZeroPrice();

        // Detect direction by comparing amounts via price
        // If tokenIn → tokenOut at price: player→collateral: out = in * price / 1e18
        // collateral→player: out = in * 1e18 / price
        // We infer: if amountIn * price / 1e18 looks like collateral out, else player out.
        // Explicit: caller always swaps between the two; use balance of msg.sender pull.
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Heuristic: if converting "down" in value units via priceWad as collat/token
        // We need to know which token is player. Encode: price applies as
        //   outCollateral = inPlayer * price / 1e18
        //   outPlayer = inCollateral * 1e18 / price
        // Detect by checking which conversion yields amountOutMin satisfaction preference:
        // Try player→collateral first if amountIn * price / 1e18 >= amountOutMin OR always use
        // tagged pairs via constructor — store token addresses.
        amountOut = _quote(tokenIn, tokenOut, amountIn);
        if (amountOut < amountOutMin) revert Slippage();
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    function swapExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 amountInMax,
        uint256 deadline
    ) external returns (uint256 amountIn) {
        if (block.timestamp > deadline) revert Deadline();
        if (priceWad == 0) revert ZeroPrice();

        amountIn = _quoteIn(tokenIn, tokenOut, amountOut);
        if (amountIn > amountInMax) revert Slippage();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    address public playerToken;
    address public collateral;

    function setTokens(address playerToken_, address collateral_) external {
        playerToken = playerToken_;
        collateral = collateral_;
    }

    function _quote(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        if (tokenIn == playerToken && tokenOut == collateral) {
            return (amountIn * priceWad) / 1e18;
        }
        if (tokenIn == collateral && tokenOut == playerToken) {
            return (amountIn * 1e18) / priceWad;
        }
        revert ZeroPrice();
    }

    function _quoteIn(address tokenIn, address tokenOut, uint256 amountOut) internal view returns (uint256) {
        if (tokenIn == collateral && tokenOut == playerToken) {
            return (amountOut * priceWad) / 1e18;
        }
        if (tokenIn == playerToken && tokenOut == collateral) {
            return (amountOut * 1e18) / priceWad;
        }
        revert ZeroPrice();
    }
}
