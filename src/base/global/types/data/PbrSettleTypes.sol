// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title PbrSettleTypes
 * @notice Types for per-fixture `SettleDms` → treasury `applyFixtureSettlement`.
 */

enum RoundSettlePhase {
    None,
    /// @dev Fixture oracle jobs opened
    Requested,
    /// @dev Every fixture proven and applied; treasury is Claimable
    Complete
}

enum FixturePhase {
    None,
    Requested,
    Proven
}

/// @notice Aggregate settle progress for one tournament round
struct RoundSettlement {
    RoundSettlePhase phase;
    address treasury;
    bytes32 tournamentId;
    uint16 season;
    uint32 roundNumber;
    bytes32 utilizedHash;
    uint32 fixturesExpected;
    uint32 fixturesSettled;
}

/// @notice Per-fixture zk settle record
struct FixtureSettlement {
    FixturePhase phase;
    bytes32 fixtureId;
    bytes32 fixtureDigest;
    bytes32 proofHash;
    bytes32 requestId;
}

struct PendingSettle {
    address treasury;
    bytes32 tournamentId;
    uint16 season;
    uint32 roundNumber;
    bytes32 fixtureId;
    bytes32 utilizedHash;
}
