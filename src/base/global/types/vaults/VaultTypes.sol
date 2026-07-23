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
    /// @dev `m` / `M_adj` written; users may pull-claim (challenge window can gate this later)
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
}
