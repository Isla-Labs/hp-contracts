// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";

import { DeploymentsErrors as Errors } from "@errors/lockers/DeploymentsErrors.sol";
import { IOrchestrator } from "@interfaces/IOrchestrator.sol";

/**
 * @title Orchestrator
 * @notice Privileged call relay for protocol contracts that set this address as `owner`.
 * @dev Access:
 *        - `DEFAULT_ADMIN_ROLE` — EOA at bootstrap, Safe multisig in production. Role admin +
 *          may `execute`. Transfer via `transferDefaultAdmin` (atomic grant + revoke).
 *        - `AUTHORIZED_CONTRACT` — modules (e.g. `DeployTournament`, future data keepers)
 *          that may submit calls through this contract.
 *
 *      Targets always see `msg.sender == address(this)`, so Ownable dependents authorize
 *      the Orchestrator rather than each caller.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract Orchestrator is AccessControl, IOrchestrator {
    /// @notice Modules allowed to relay calls (in addition to `DEFAULT_ADMIN_ROLE`).
    bytes32 public constant AUTHORIZED_CONTRACT = keccak256("AUTHORIZED_CONTRACT");

    /// @notice Emitted when `DEFAULT_ADMIN_ROLE` moves from `previousAdmin` to `newAdmin`.
    event DefaultAdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    /**
     * @param admin_ EOA or Safe — `DEFAULT_ADMIN_ROLE`.
     */
    constructor(address admin_) {
        if (admin_ == address(0)) revert Errors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    // --------------------------------------------
    //  Role admin helpers
    // --------------------------------------------

    /// @notice Grant `AUTHORIZED_CONTRACT` to a module (e.g. `DeployTournament`).
    function addAuthorizedContract(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert Errors.ZeroAddress();
        _grantRole(AUTHORIZED_CONTRACT, account);
    }

    /// @notice Revoke `AUTHORIZED_CONTRACT` from a module.
    function removeAuthorizedContract(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(AUTHORIZED_CONTRACT, account);
    }

    /// @notice Atomically move `DEFAULT_ADMIN_ROLE` from the caller to `newAdmin`.
    function transferDefaultAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin == address(0)) revert Errors.ZeroAddress();
        address previousAdmin = _msgSender();
        if (newAdmin == previousAdmin) return;
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        _revokeRole(DEFAULT_ADMIN_ROLE, previousAdmin);
        emit DefaultAdminTransferred(previousAdmin, newAdmin);
    }

    // --------------------------------------------
    //  Execute
    // --------------------------------------------

    /// @inheritdoc IOrchestrator
    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory result) {
        _checkAdminOrAuthorized();
        if (target == address(0)) revert Errors.ZeroAddress();
        (bool ok, bytes memory ret) = target.call{ value: value }(data);
        if (!ok) revert Errors.ExecutionFailed(target, ret);
        return ret;
    }

    /// @inheritdoc IOrchestrator
    function executeBatch(Call[] calldata calls) external returns (bytes[] memory results) {
        _checkAdminOrAuthorized();
        uint256 length = calls.length;
        results = new bytes[](length);
        for (uint256 i; i < length;) {
            address target = calls[i].target;
            if (target == address(0)) revert Errors.ZeroAddress();
            (bool ok, bytes memory ret) = target.call{ value: calls[i].value }(calls[i].data);
            if (!ok) revert Errors.ExecutionFailed(target, ret);
            results[i] = ret;
            unchecked {
                ++i;
            }
        }
    }

    function _checkAdminOrAuthorized() internal view {
        address sender = _msgSender();
        if (!hasRole(DEFAULT_ADMIN_ROLE, sender) && !hasRole(AUTHORIZED_CONTRACT, sender)) {
            revert Errors.Unauthorized();
        }
    }
}
