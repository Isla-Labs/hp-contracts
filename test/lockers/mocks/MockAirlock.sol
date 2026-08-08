// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Minimal Airlock stub for DopplerConfig.owner() reads.
contract MockAirlock {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }
}
