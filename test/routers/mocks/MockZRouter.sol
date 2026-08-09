// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { MockPlayerToken } from "../../vaults/mocks/MockPlayerToken.sol";

/// @notice Minimal zRouter stand-in: 1:1 ERC20↔ETH for TradeRouter wing tests.
contract MockZRouter {
    error TransferFailed();

    receive() external payable {}

    /// @dev Pulls `amountIn` of `tokenIn` from caller and sends the same wei of ETH to `to`.
    function swapToEth(address tokenIn, uint256 amountIn, address to) external {
        require(MockPlayerToken(tokenIn).transferFrom(msg.sender, address(this), amountIn), "pull");
        (bool ok,) = to.call{ value: amountIn }("");
        if (!ok) revert TransferFailed();
    }

    /// @dev Mints `msg.value` of `tokenOut` to `to` (simulates ETH→ERC20 exact-in).
    function swapFromEth(address tokenOut, address to) external payable {
        MockPlayerToken(tokenOut).mint(to, msg.value);
    }
}
