// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IAutomator
 * @notice Cat-3 relay: verified callers execute privileged protocol actions as this contract.
 * @dev Any destination is callable; targets enforce their own Automator-only access.
 *      Verified callers are a dedicated allowlist (not AccessControl roles), managed by CAT_ONE.
 */
interface IAutomator {
    function isVerifiedCaller(address caller) external view returns (bool);

    function verifiedCallers() external view returns (address[] memory);

    /// @dev `CATEGORY_ONE` — add a verified caller.
    function addAutomator(address caller) external;

    /// @dev `CATEGORY_ONE` — remove a verified caller.
    function removeAutomator(address caller) external;

    function executeAutomation(
        address target,
        uint256 value,
        bytes calldata data
    ) external payable returns (bytes memory result);
}
