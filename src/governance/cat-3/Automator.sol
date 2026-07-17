// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { AccessRoles as Roles } from "@base/global/libraries/roles/AccessRoles.sol";
import { GovernanceEvents as Events } from "@base/global/libraries/events/GovernanceEvents.sol";
import { GovernanceErrors as Errors } from "@base/global/libraries/errors/GovernanceErrors.sol";

contract Automator is AccessControl {
    address public immutable UPDATE_AUTHORITY;

    constructor(
        address dao_, 
        address constitutional_,
        address doppler_, 
        address lifecycles_, 
        address matchweeks_, 
        address updateAuthority_
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        
        _grantRole(Roles.CATEGORY_ONE, constitutional_);

        _grantRole(Roles.CATEGORY_THREE, doppler_);
        _grantRole(Roles.CATEGORY_THREE, lifecycles_);
        _grantRole(Roles.CATEGORY_THREE, matchweeks_);

        UPDATE_AUTHORITY = updateAuthority_;
    }

    /**
     * @notice Add a new automator to the category.
     * @param automator_ The address of the automator to add.
     */
    function addAutomator(address automator_) external onlyRole(Roles.CATEGORY_ONE) {
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
     * @notice Execute an arbitrary call to the UpdateAuthority.
     * @param value ETH to forward.
     * @param data Calldata for `target`.
     * @return result Return data from the call.
     */
    function executeAutomation(uint256 value, bytes calldata data)
        external
        payable
        onlyRole(Roles.CATEGORY_THREE)
        returns (bytes memory result)
    {
        (bool ok, bytes memory ret) = UPDATE_AUTHORITY.call{ value: value }(data);
        if (!ok) revert Errors.ExecutionFailed();
        emit Events.AutomationExecuted(UPDATE_AUTHORITY, value, data, ret);
        return ret;
    }
}
