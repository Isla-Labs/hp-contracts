// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library RoutersEvents {
    event Staked(address indexed user, address indexed token, address indexed vault, uint256 amount);
    event Unstaked(address indexed user, address indexed token, address indexed vault, uint256 amount);
    event Claimed(address indexed user, address indexed token, address indexed vault, uint256 payout);

    event Bought(
        address indexed user,
        address indexed playerToken,
        uint256 ethIn,
        uint256 amountOut
    );
    event Sold(
        address indexed user,
        address indexed playerToken,
        uint256 amountIn,
        uint256 ethOut
    );
}
