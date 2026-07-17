// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { AccessRoles as Roles } from "@base/global/libraries/roles/AccessRoles.sol";
import { GovernanceEvents as Events } from "@base/global/libraries/events/GovernanceEvents.sol";
import { GovernanceErrors as Errors } from "@base/global/libraries/errors/GovernanceErrors.sol";

/**
 * @title Automator
 * @notice Cat-3 privileged caller for automated / data-driven protocol actions.
 * @dev Allowlisted automators (`CATEGORY_THREE`) execute arbitrary calls as this contract.
 *      Targets see `msg.sender == address(this)`. `ConstitutionalTimelock` (`CATEGORY_ONE`)
 *      may add/remove automators. Aragon DAO holds `DEFAULT_ADMIN_ROLE`.
 */
contract Automator is AccessControl {
    /**
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE`.
     * @param constitutional_ `ConstitutionalTimelock` — `CATEGORY_ONE` (add/remove automators).
     * @param doppler_ Initial Doppler automator — `CATEGORY_THREE`.
     * @param lifecycles_ Initial lifecycle automator — `CATEGORY_THREE`.
     * @param matchweeks_ Initial matchweek automator — `CATEGORY_THREE`.
     */
    constructor(address dao_, address constitutional_, address doppler_, address lifecycles_, address matchweeks_) {
        if (
            dao_ == address(0) || constitutional_ == address(0) || doppler_ == address(0) || lifecycles_ == address(0)
                || matchweeks_ == address(0)
        ) revert Errors.ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_ONE, constitutional_);
        _grantRole(Roles.CATEGORY_THREE, doppler_);
        _grantRole(Roles.CATEGORY_THREE, lifecycles_);
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
    function executeAutomation(address target, uint256 value, bytes calldata data)
        external
        payable
        onlyRole(Roles.CATEGORY_THREE)
        returns (bytes memory result)
    {
        if (target == address(0)) revert Errors.ZeroAddress();
        (bool ok, bytes memory ret) = target.call{ value: value }(data);
        if (!ok) revert Errors.ExecutionFailed();
        emit Events.AutomationExecuted(target, value, data, ret);
        return ret;
    }
}
