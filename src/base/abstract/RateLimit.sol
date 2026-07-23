// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

abstract contract RateLimit {
    uint256 public immutable cooldown;
    uint256 private lastExecution;

    error ZeroCooldown();
    error RateLimited(uint256 unlockAt);

    constructor(uint256 cooldown_) {
        if (cooldown_ == 0) revert ZeroCooldown();
        cooldown = cooldown_;
    }

    modifier rateLimited() {
        uint256 last = lastExecution;
        if (last != 0) {
            uint256 unlockAt = last + cooldown;
            if (block.timestamp < unlockAt) revert RateLimited(unlockAt);
        }
        _;
        lastExecution = block.timestamp;
    }

    function nextAllowed() external view returns (uint256 timestamp) {
        uint256 last = lastExecution;
        if (last == 0) return 0;
        return last + cooldown;
    }
}