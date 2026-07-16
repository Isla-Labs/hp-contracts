// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title GovernanceTypes
 * @notice Shared types for HP governance executors and Aragon action encoding.
 * @dev Decision classes (see `governance/plan/governancePlan.md`):
 *      - Class1Zk: proof/data-gated; no DAO vote under normal operation
 *      - Class2Ops: Multisig / short-delay operational bundles
 *      - Class3Constitutional: TokenVoting + long timelock (upgrades, vkeys, criteria)
 */
library GovernanceTypes {
    /// @notice Single call in a scheduled or DAO-executed batch (Aragon-compatible shape)
    struct Action {
        address to;
        uint256 value;
        bytes data;
    }

    /// @notice Governance decision class for documentation / offchain indexing
    enum DecisionClass {
        Class1Zk,
        Class2Ops,
        Class3Constitutional
    }
}
