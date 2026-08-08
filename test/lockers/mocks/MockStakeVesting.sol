// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

contract MockStakeVesting {
    uint256 public allocateCount;

    function allocate(address, uint256) external {
        unchecked {
            ++allocateCount;
        }
    }
}
