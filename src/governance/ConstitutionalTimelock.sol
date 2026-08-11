// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { TimelockController } from "@openzeppelin/governance/TimelockController.sol";
import { GovernanceErrors as Errors } from "@errors/governance/GovernanceErrors.sol";

/**
 * @title ConstitutionalTimelock
 * @notice Long-delay executor for protocol-level changes.
 * @dev OZ `TimelockController` with a fixed target allowlist:
 *      - `addressProvider` / `deployTournament` (immutable)
 *      - `address(this)` (required for `updateDelay` and self-admin ops)
 *      Checks run at schedule and execute.
 */
contract ConstitutionalTimelock is TimelockController {
    /// @notice Default constitutional notice window.
    uint256 public constant DEFAULT_MIN_DELAY = 7 days;

    /// @notice Sole registry mutation surface for cat-1 name updates.
    address public immutable addressProvider;

    /// @notice Tournament bootstrap module (league / season create path).
    address public immutable deployTournament;

    /**
     * @notice Deploys with the Aragon DAO as sole proposer/canceller and open execution.
     * @param dao Aragon DAO address (`PROPOSER_ROLE`, `CANCELLER_ROLE`, optional `DEFAULT_ADMIN_ROLE`).
     * @param addressProvider_ Protocol `AddressProvider`.
     * @param deployTournament_ `DeployTournament` proxy.
     * @param minDelay Delay in seconds between schedule and execute; `0` → `DEFAULT_MIN_DELAY`.
     */
    constructor(
        address dao,
        address addressProvider_,
        address deployTournament_,
        uint256 minDelay
    ) TimelockController(minDelay == 0 ? DEFAULT_MIN_DELAY : minDelay, _singleton(dao), _openExecutors(), dao) {
        if (dao == address(0) || addressProvider_ == address(0) || deployTournament_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        addressProvider = addressProvider_;
        deployTournament = deployTournament_;
    }

    /// @inheritdoc TimelockController
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override onlyRole(PROPOSER_ROLE) {
        _requireAllowedTarget(target);
        super.schedule(target, value, data, predecessor, salt, delay);
    }

    /// @inheritdoc TimelockController
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override onlyRole(PROPOSER_ROLE) {
        uint256 length = targets.length;
        for (uint256 i; i < length;) {
            _requireAllowedTarget(targets[i]);
            unchecked {
                ++i;
            }
        }
        super.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
    }

    /// @inheritdoc TimelockController
    function _execute(address target, uint256 value, bytes calldata data) internal override {
        _requireAllowedTarget(target);
        super._execute(target, value, data);
    }

    function _requireAllowedTarget(address target) private view {
        if (target != addressProvider && target != deployTournament && target != address(this)) {
            revert Errors.TargetNotAllowed(target);
        }
    }

    function _singleton(address account) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _openExecutors() private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = address(0);
    }
}
