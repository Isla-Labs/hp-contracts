// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IAutomator
 * @notice Cat-3 relay: verified callers execute actions as this contract against allowlisted destinations.
 * @dev Targets still enforce their own Automator-only access. Admin is `CATEGORY_ONE`.
 */
interface IAutomator {
    function isVerifiedCaller(address caller) external view returns (bool);

    function isVerifiedDestination(address caller, address target) external view returns (bool);

    function verifiedCallers() external view returns (address[] memory);

    function verifiedDestinations(address caller) external view returns (address[] memory);

    /// @dev `CATEGORY_ONE` — add caller with at least one destination.
    function addAutomator(address caller, address[] calldata destinations) external;

    /// @dev `CATEGORY_ONE` — remove caller and clear its destinations.
    function removeAutomator(address caller) external;

    /// @dev `CATEGORY_ONE` — add one destination for an existing caller.
    function addDestination(address caller, address target) external;

    /// @dev `CATEGORY_ONE` — remove one destination for an existing caller.
    function removeDestination(address caller, address target) external;

    function executeAutomation(
        address target,
        uint256 value,
        bytes calldata data
    ) external payable returns (bytes memory result);
}
