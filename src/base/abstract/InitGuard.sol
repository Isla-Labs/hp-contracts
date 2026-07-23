// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

contract InitGuard {
    fallback() external payable {
        revert("UNINITIALIZED");
    }

    receive() external payable {
        revert("UNINITIALIZED");
    }
}
