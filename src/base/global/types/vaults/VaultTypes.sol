// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title VaultTypes
 * @notice Shared types for PBR round settlement and vault snapshots.
 */

/// @notice Lifecycle of a cup round's rewards pot
enum RoundStatus {
    None,
    /// @dev `R` frozen at mwStartTime; stake snapshots in progress / complete
    Locked,
    /// @dev Per-fixture `SettleDms` jobs open; awaiting zk fulfills
    SettlePending,
    /// @dev All fixtures applied; users may pull-claim
    Claimable
}

/// @notice Per-season, per-round rewards accounting on a single-tournament `PbrTreasury`
struct RoundState {
    RoundStatus status;
    uint256 R;
    uint256 M_adj;
    uint256 paid;
    uint64 startTime;
    uint64 endTime;
    uint32 fixturesExpected;
    uint32 fixturesSettled;
}
