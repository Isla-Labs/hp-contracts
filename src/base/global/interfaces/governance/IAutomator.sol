// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IAutomator
 * @notice Cat-3 relay: allowlisted callers execute privileged protocol actions as this contract.
 */
interface IAutomator {
    function executeAutomation(address target, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory result);
}
