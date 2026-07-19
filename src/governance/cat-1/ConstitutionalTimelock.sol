// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { TimelockController } from "@openzeppelin/governance/TimelockController.sol";
import { GovernanceErrors as Errors } from "@base/global/libraries/errors/GovernanceErrors.sol";

/**
 * @title ConstitutionalTimelock
 * @notice Cat-1 long-delay executor for upgrades, fee splits, and other constitutional actions.
 * @dev Thin OZ `TimelockController`. The Aragon DAO is the sole proposer (and canceller). Multisig /
 *      TokenVoting / VE reach this contract only via `DAO.execute` → `schedule` / `scheduleBatch`.
 *      After `minDelay`, anyone may `execute` / `executeBatch` (`EXECUTOR_ROLE` on `address(0)`).
 *      Targets see `msg.sender == address(this)`.
 *
 *      Wire this contract as:
 *      - `UpgradeableBeacon` owner / Transparent `ProxyAdmin` owner / UUPS upgrade authority
 *      - Holder of constitutional / CATEGORY_ONE roles on protocol contracts
 *
 *      Day-one: `admin` = DAO for bootstrap; later renounce so role/delay changes go through the
 *      timelock itself. Ops upkeep is cat-2; automation is cat-3 (`Automator`).
 */
contract ConstitutionalTimelock is TimelockController {
    /// @notice Default constitutional notice window.
    uint256 public constant DEFAULT_MIN_DELAY = 7 days;

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
