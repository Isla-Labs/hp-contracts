// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Records utilization flips from PlayerVault stake/unstake.
contract MockPlayerSetRegistry {
    bool public lastUtilized;
    uint256 public updateCount;
    address public lastCaller;

    function updateUtilization(bool isUtilized) external {
        lastUtilized = isUtilized;
        lastCaller = msg.sender;
        unchecked {
            ++updateCount;
        }
    }
}
