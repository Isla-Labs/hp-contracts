// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title GovernanceTypes
 * @notice Shared types for HP governance executors and Aragon action encoding.
 * @dev Categories:
 *      - Cat1Constitutional: long-delay major protocol changes
 *      - Cat2Ops: short-delay operational maintenance
 *      - Cat3Immediate: privileged execution with no protocol delay (`UpdateAuthority`)
 */
library GovernanceTypes {
    /// @notice Single call in a scheduled or DAO-executed batch (Aragon-compatible shape)
    struct Action {
        address to;
        uint256 value;
        bytes data;
    }

    /// @notice Governance category for documentation / offchain indexing
    enum DecisionClass {
        Cat1Constitutional,
        Cat2Ops,
        Cat3Immediate
    }
}
