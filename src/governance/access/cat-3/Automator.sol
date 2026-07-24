// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { AccessRoles as Roles } from "@roles/AccessRoles.sol";
import { GovernanceEvents as Events } from "@events/governance/GovernanceEvents.sol";
import { GovernanceErrors as Errors } from "@errors/governance/GovernanceErrors.sol";
import { IAutomator } from "@interfaces/governance/IAutomator.sol";

/**
 * @title Automator
 * @notice Cat-3 privileged relay for automated / data-driven protocol actions.
 * @dev Verified callers are a dedicated allowlist (separate from AccessControl roles).
 *      They may `executeAutomation` to any destination; destinations enforce their own
 *      access (typically only this contract holds CAT_THREE / sole-writer on the target).
 *      DAO / CAT_ONE roles only govern who may edit the allowlist.
 *      See `../README.md` for the cat-1 / cat-2 / cat-3 privilege model.
 */
contract Automator is AccessControl, IAutomator {
    /// @notice Enumerable verified-caller set.
    address[] private _verifiedCallers;

    /// @notice O(1) membership for `executeAutomation`.
    mapping(address caller => bool) public isVerifiedCaller;

    /// @dev 1-based index into `_verifiedCallers` (0 = absent).
    mapping(address caller => uint256) private _verifiedCallerIndex;

    /**
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE`.
     * @param constitutional_ `ConstitutionalTimelock` — `CATEGORY_ONE` (add/remove callers).
     * @param verifiedCallers_ Day-one verified callers (non-empty).
     */
    constructor(address dao_, address constitutional_, address[] memory verifiedCallers_) {
        if (dao_ == address(0) || constitutional_ == address(0)) revert Errors.ZeroAddress();
        if (verifiedCallers_.length == 0) revert Errors.EmptyVerifiedCallers();

        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_ONE, constitutional_);

        uint256 length = verifiedCallers_.length;
        for (uint256 i; i < length; ++i) {
            _addVerifiedCaller(verifiedCallers_[i]);
        }
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc IAutomator
    function verifiedCallers() external view returns (address[] memory) {
        return _verifiedCallers;
    }

    // --------------------------------------------
    //  Admin — verified callers
    // --------------------------------------------

    /// @inheritdoc IAutomator
    function addAutomator(address caller) external onlyRole(Roles.CATEGORY_ONE) {
        _addVerifiedCaller(caller);
    }

    /// @inheritdoc IAutomator
    function removeAutomator(address caller) external onlyRole(Roles.CATEGORY_ONE) {
        _removeVerifiedCaller(caller);
    }

    // --------------------------------------------
    //  Category-3 Automation
    // --------------------------------------------

    /// @inheritdoc IAutomator
    function executeAutomation(
        address target,
        uint256 value,
        bytes calldata data
    ) external payable returns (bytes memory result) {
        if (!isVerifiedCaller[msg.sender]) revert Errors.NotVerifiedCaller(msg.sender);
        if (target == address(0)) revert Errors.ZeroAddress();

        (bool ok, bytes memory ret) = target.call{ value: value }(data);
        if (!ok) revert Errors.ExecutionFailed();
        emit Events.AutomationExecuted(target, value, data, ret);
        return ret;
    }

    // --------------------------------------------
    //  Internal
    // --------------------------------------------

    function _addVerifiedCaller(address caller) private {
        if (caller == address(0)) revert Errors.ZeroAddress();
        if (isVerifiedCaller[caller]) revert Errors.AlreadyVerifiedCaller(caller);

        _verifiedCallers.push(caller);
        _verifiedCallerIndex[caller] = _verifiedCallers.length; // 1-based
        isVerifiedCaller[caller] = true;
    }

    function _removeVerifiedCaller(address caller) private {
        if (caller == address(0)) revert Errors.ZeroAddress();
        uint256 index = _verifiedCallerIndex[caller]; // 1-based
        if (index == 0) revert Errors.NotVerifiedCaller(caller);

        uint256 lastIndex = _verifiedCallers.length; // 1-based length
        address lastCaller = _verifiedCallers[lastIndex - 1];

        if (index != lastIndex) {
            _verifiedCallers[index - 1] = lastCaller;
            _verifiedCallerIndex[lastCaller] = index;
        }

        _verifiedCallers.pop();
        delete _verifiedCallerIndex[caller];
        delete isVerifiedCaller[caller];
    }
}
