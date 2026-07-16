// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { TimelockController } from "@openzeppelin/governance/TimelockController.sol";

/**
 * @title ConstitutionalTimelock
 * @notice Long-delay OZ TimelockController for Class-3 (constitutional) actions.
 * @dev Intended holders after handoff:
 *      - `admin` / role admin: Aragon DAO (then self-admin via timelock for delay changes)
 *      - `PROPOSER_ROLE`: Aragon DAO (TokenVoting/Multisig → `DAO.execute` → `schedule`)
 *      - `EXECUTOR_ROLE`: open (`address(0)`) or DAO
 *      - `CANCELLER_ROLE`: Security Council (via DAO grant) for upgrade veto during delay
 *
 *      Own this contract as:
 *      - `UpgradeableBeacon` owner (FeeRouter / PbrFeeHub)
 *      - Proxy admin / UUPS owner for registries & verifiers
 *      - Admin for PPM / eligibility vkey + `CriteriaRegistry` updates
 *
 *      Suggested `minDelay`: 7–14 days (see governance plan).
 */
contract ConstitutionalTimelock is TimelockController {
    /**
     * @param minDelay Minimum delay between schedule and execute.
     * @param proposers Accounts granted `PROPOSER_ROLE` (typically the Aragon DAO).
     * @param executors Accounts granted `EXECUTOR_ROLE` (use `[address(0)]` for open execution).
     * @param admin Optional temporary admin for role bootstrap (Aragon DAO); may be zero to
     *        self-administer immediately after deploy.
     */
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    {}
}
