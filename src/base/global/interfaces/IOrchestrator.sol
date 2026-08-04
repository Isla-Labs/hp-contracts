// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IOrchestrator
 * @notice Privileged call relay — `msg.sender` on targets is the Orchestrator (Ownable owner).
 */
interface IOrchestrator {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice Atomically move `DEFAULT_ADMIN_ROLE` from caller to `newAdmin` (EOA → Safe).
    function transferDefaultAdmin(address newAdmin) external;

    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory result);

    function executeBatch(Call[] calldata calls) external returns (bytes[] memory results);
}
