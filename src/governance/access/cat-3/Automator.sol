// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { AccessRoles as Roles } from "@roles/AccessRoles.sol";
import { GovernanceEvents as Events } from "@events/governance/GovernanceEvents.sol";
import { GovernanceErrors as Errors } from "@errors/governance/GovernanceErrors.sol";
import { IAutomator } from "@interfaces/governance/IAutomator.sol";

/**
 * @title Automator
 * @notice Cat-3 privileged caller for automated / data-driven protocol actions.
 * @dev Allowlisted `CATEGORY_THREE` operators call `executeAutomation`; targets see this contract
 *      as `msg.sender`. See `../README.md` for the cat-1 / cat-2 / cat-3 privilege model.
 */
contract Automator is AccessControl, IAutomator {
    /**
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE`.
     * @param constitutional_ `ConstitutionalTimelock` — `CATEGORY_ONE` (add/remove automators).
     * @param doppler_ Initial Doppler automator — `CATEGORY_THREE`.
     * @param eligibilityVerifier_ `EligibilityVerifier` — `CATEGORY_THREE` (lifecycle / discontinue).
     * @param matchweeks_ Initial matchweek automator — `CATEGORY_THREE`.
     */
    constructor(
        address dao_,
        address constitutional_,
        address doppler_,
        address eligibilityVerifier_,
        address matchweeks_
    ) {
        if (
            dao_ == address(0) || constitutional_ == address(0) || doppler_ == address(0)
                || eligibilityVerifier_ == address(0) || matchweeks_ == address(0)
        ) revert Errors.ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_ONE, constitutional_);
        _grantRole(Roles.CATEGORY_THREE, doppler_);
        _grantRole(Roles.CATEGORY_THREE, eligibilityVerifier_);
        _grantRole(Roles.CATEGORY_THREE, matchweeks_);
    }

    /**
     * @notice Add a new automator to the category.
     * @param automator_ The address of the automator to add.
     */
    function addAutomator(address automator_) external onlyRole(Roles.CATEGORY_ONE) {
        if (automator_ == address(0)) revert Errors.ZeroAddress();
        _grantRole(Roles.CATEGORY_THREE, automator_);
    }

    /**
     * @notice Remove an automator from the category.
     * @param automator_ The address of the automator to remove.
     */
    function removeAutomator(address automator_) external onlyRole(Roles.CATEGORY_ONE) {
        _revokeRole(Roles.CATEGORY_THREE, automator_);
    }

    /**
     * @notice Execute an arbitrary call as this contract.
     * @param target Contract to call.
     * @param value ETH to forward.
     * @param data Calldata for `target`.
     * @return result Return data from the call.
     */
    /// @inheritdoc IAutomator
    function executeAutomation(
        address target,
        uint256 value,
        bytes calldata data
    ) external payable onlyRole(Roles.CATEGORY_THREE) returns (bytes memory result) {
        if (target == address(0)) revert Errors.ZeroAddress();
        (bool ok, bytes memory ret) = target.call{ value: value }(data);
        if (!ok) revert Errors.ExecutionFailed();
        emit Events.AutomationExecuted(target, value, data, ret);
        return ret;
    }
}
