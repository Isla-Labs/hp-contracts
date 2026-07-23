// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { TimelockController } from "@openzeppelin/governance/TimelockController.sol";
import { GovernanceErrors as Errors } from "@base/global/libraries/errors/GovernanceErrors.sol";

/**
 * @title MaintenanceTimelock
 * @notice Cat-2 short-delay executor for standard manual upkeep (sweeps, pause/resume, status fixes).
 * @dev Same shape as `ConstitutionalTimelock`: Aragon DAO is sole proposer/canceller; open execution
 *      after `minDelay`. Multisig / TokenVoting reach this via `DAO.execute` → `schedule`.
 *      Targets see `msg.sender == address(this)`.
 *
 *      Wire this contract as holder of maintenance / CATEGORY_TWO roles on protocol contracts.
 *      Not for upgrades, fee-split constitution, or beacon admin — those stay on cat-1.
 *      Automation stays on cat-3 (`Automator`).
 */
contract MaintenanceTimelock is TimelockController {
    /// @notice Default ops notice window (shorter than constitutional).
    uint256 public constant DEFAULT_MIN_DELAY = 1 days;

    /**
     * @notice Deploys with the Aragon DAO as sole proposer/canceller and open execution.
     * @param dao Aragon DAO address (`PROPOSER_ROLE`, `CANCELLER_ROLE`, optional `DEFAULT_ADMIN_ROLE`).
     * @param minDelay Delay in seconds between schedule and execute; `0` → `DEFAULT_MIN_DELAY`.
     */
    constructor(address dao, uint256 minDelay)
        TimelockController(minDelay == 0 ? DEFAULT_MIN_DELAY : minDelay, _singleton(dao), _openExecutors(), dao)
    {
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
