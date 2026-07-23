// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { TimelockController } from "@openzeppelin/governance/TimelockController.sol";
import { GovernanceErrors as Errors } from "@errors/governance/GovernanceErrors.sol";

/**
 * @title MaintenanceTimelock
 * @notice Cat-2 short-delay executor for standard manual upkeep (sweeps, pause/resume, status fixes).
 * @dev Thin OZ `TimelockController`. See `../README.md` for the cat-1 / cat-2 / cat-3 privilege model.
 */
contract MaintenanceTimelock is TimelockController {
    /// @notice Default ops notice window (shorter than constitutional).
    uint256 public constant DEFAULT_MIN_DELAY = 1 days;

    /**
     * @notice Deploys with the Aragon DAO as sole proposer/canceller and open execution.
     * @param dao Aragon DAO address (`PROPOSER_ROLE`, `CANCELLER_ROLE`, optional `DEFAULT_ADMIN_ROLE`).
     * @param minDelay Delay in seconds between schedule and execute; `0` → `DEFAULT_MIN_DELAY`.
     */
    constructor(
        address dao,
        uint256 minDelay
    ) TimelockController(minDelay == 0 ? DEFAULT_MIN_DELAY : minDelay, _singleton(dao), _openExecutors(), dao) {
        if (dao == address(0)) revert Errors.ZeroAddress();
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
