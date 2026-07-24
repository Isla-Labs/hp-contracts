// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IAutomator
 * @notice Cat-3 relay: allowlisted callers execute privileged protocol actions as this contract.
 * @dev Destinations are bounded by a caller→target route matrix (`allowedRoute`).
 */
interface IAutomator {
    function allowedRoute(address caller, address target) external view returns (bool allowed);

    function setRoute(address caller, address target, bool allowed) external;

    function setRoutes(address[] calldata callers, address[] calldata targets, bool[] calldata allowed) external;

    function executeAutomation(
        address target,
        uint256 value,
        bytes calldata data
    ) external payable returns (bytes memory result);
}
