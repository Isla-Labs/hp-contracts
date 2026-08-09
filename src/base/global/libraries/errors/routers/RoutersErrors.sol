// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library RoutersErrors {
    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error UnknownToken(address token);
    error UnknownVault(address token);
    error TokenVaultMismatch(address token, address vaultToken);

    // TradeRouter
    error Expired();
    error Slippage();
    error InvalidPath();
    error InvalidMsgValue();
    error InvalidPool(address token);
    error ZRouterCallFailed();
    error EthTransferFailed();
}
