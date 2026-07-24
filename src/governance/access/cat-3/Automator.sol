// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { EnumerableSet } from "@openzeppelin/utils/structs/EnumerableSet.sol";
import { AccessRoles as Roles } from "@roles/AccessRoles.sol";
import { GovernanceEvents as Events } from "@events/governance/GovernanceEvents.sol";
import { GovernanceErrors as Errors } from "@errors/governance/GovernanceErrors.sol";
import { IAutomator } from "@interfaces/governance/IAutomator.sol";
import { VerifiedCallerConfig } from "@types/governance/AutomatorTypes.sol";

/**
 * @title Automator
 * @notice Cat-3 privileged relay for automated / data-driven protocol actions.
 * @dev Verified callers and per-caller destinations are dedicated allowlists (not AccessControl
 *      roles). `executeAutomation` requires both. Destinations still self-gate (typically only
 *      this contract holds CAT_THREE / sole-writer on the target).
 *      See `../README.md` for the cat-1 / cat-2 / cat-3 privilege model.
 */
contract Automator is AccessControl, IAutomator {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _verifiedCallers;
    mapping(address caller => EnumerableSet.AddressSet) private _destinationsOf;

    /**
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE`.
     * @param constitutional_ `ConstitutionalTimelock` — `CATEGORY_ONE`.
     * @param configs_ Day-one callers, each with a non-empty destination set.
     */
    constructor(address dao_, address constitutional_, VerifiedCallerConfig[] memory configs_) {
        if (dao_ == address(0) || constitutional_ == address(0)) revert Errors.ZeroAddress();
        if (configs_.length == 0) revert Errors.EmptyVerifiedCallers();

        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_ONE, constitutional_);

        uint256 length = configs_.length;
        for (uint256 i; i < length; ++i) {
            _addVerifiedCaller(configs_[i].caller, configs_[i].destinations);
        }
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
        if (!_verifiedCallers.contains(msg.sender)) revert Errors.NotVerifiedCaller(msg.sender);
        if (target == address(0)) revert Errors.ZeroAddress();
        if (!_destinationsOf[msg.sender].contains(target)) {
            revert Errors.DestinationNotAllowed(msg.sender, target);
        }

        (bool ok, bytes memory ret) = target.call{ value: value }(data);
        if (!ok) revert Errors.ExecutionFailed();
        emit Events.AutomationExecuted(target, value, data, ret);
        return ret;
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc IAutomator
    function isVerifiedCaller(address caller) public view returns (bool) {
        return _verifiedCallers.contains(caller);
    }

    /// @inheritdoc IAutomator
    function isVerifiedDestination(address caller, address target) public view returns (bool) {
        return _destinationsOf[caller].contains(target);
    }

    /// @inheritdoc IAutomator
    function verifiedCallers() external view returns (address[] memory) {
        return _verifiedCallers.values();
    }

    /// @inheritdoc IAutomator
    function verifiedDestinations(address caller) external view returns (address[] memory) {
        return _destinationsOf[caller].values();
    }

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    /// @inheritdoc IAutomator
    function addAutomator(address caller, address[] calldata destinations) external onlyRole(Roles.CATEGORY_ONE) {
        _addVerifiedCaller(caller, destinations);
    }

    /// @inheritdoc IAutomator
    function removeAutomator(address caller) external onlyRole(Roles.CATEGORY_ONE) {
        if (caller == address(0)) revert Errors.ZeroAddress();
        if (!_verifiedCallers.remove(caller)) revert Errors.NotVerifiedCaller(caller);

        EnumerableSet.AddressSet storage dests = _destinationsOf[caller];
        address[] memory snapshot = dests.values();
        uint256 length = snapshot.length;
        for (uint256 i; i < length; ++i) {
            address target = snapshot[i];
            dests.remove(target);
            emit Events.VerifiedDestinationRemoved(caller, target);
        }

        emit Events.VerifiedCallerRemoved(caller);
    }

    /// @inheritdoc IAutomator
    function addDestination(address caller, address target) external onlyRole(Roles.CATEGORY_ONE) {
        if (!_verifiedCallers.contains(caller)) revert Errors.NotVerifiedCaller(caller);
        _addDestination(caller, target);
    }

    /// @inheritdoc IAutomator
    function removeDestination(address caller, address target) external onlyRole(Roles.CATEGORY_ONE) {
        if (!_verifiedCallers.contains(caller)) revert Errors.NotVerifiedCaller(caller);
        if (target == address(0)) revert Errors.ZeroAddress();
        if (!_destinationsOf[caller].remove(target)) revert Errors.NotVerifiedDestination(caller, target);
        emit Events.VerifiedDestinationRemoved(caller, target);
    }

    // --------------------------------------------
    //  Internal
    // --------------------------------------------

    function _addVerifiedCaller(address caller, address[] memory destinations) private {
        if (caller == address(0)) revert Errors.ZeroAddress();
        if (destinations.length == 0) revert Errors.EmptyDestinations();
        if (!_verifiedCallers.add(caller)) revert Errors.AlreadyVerifiedCaller(caller);

        emit Events.VerifiedCallerAdded(caller);

        uint256 length = destinations.length;
        for (uint256 i; i < length; ++i) {
            _addDestination(caller, destinations[i]);
        }
    }

    function _addDestination(address caller, address target) private {
        if (target == address(0)) revert Errors.ZeroAddress();
        if (!_destinationsOf[caller].add(target)) revert Errors.AlreadyVerifiedDestination(caller, target);
        emit Events.VerifiedDestinationAdded(caller, target);
    }
}
