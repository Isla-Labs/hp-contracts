// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/**
 * @title RateLimiter
 * @notice Abstract contract for rate limiting actions.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
abstract contract RateLimiter {
    // --------------------------------------------
    //  State Variables
    // --------------------------------------------

    /// @notice The cooldown period in seconds
    uint256 public immutable cooldown;

    /// @notice The timestamp of the last execution
    uint256 private lastExecution;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    /// @notice Thrown when the action is rate limited
    error RateLimited(uint256 nextAllowed);

    /// @notice Thrown when the cooldown is zero
    error ZeroCooldown();

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    constructor(uint256 cooldown_) {
        if (cooldown_ == 0) revert ZeroCooldown();
        cooldown = cooldown_;
    }

    // --------------------------------------------
    //  Limiter
    // --------------------------------------------

    /// @notice Modifier to prevent spam
    modifier rateLimited() {
        uint256 last = lastExecution;
        if (last != 0) {
            uint256 unlockAt = last + cooldown;
            if (block.timestamp < unlockAt) revert RateLimited(unlockAt);
        }
        _;
        lastExecution = block.timestamp;
    }

    // --------------------------------------------
    //  Public Functions
    // --------------------------------------------

    /// @notice Returns the timestamp when the next action is allowed
    function nextAllowed() external view returns (uint256 timestamp) {
        uint256 last = lastExecution;
        if (last == 0) return 0;
        return last + cooldown;
    }
}
