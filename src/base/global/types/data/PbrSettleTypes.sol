// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title PbrSettleTypes
 * @notice Types for the `CvmJob.SettleDms` → `PbrTreasury.finalizeRound` pipeline.
 */

/// @notice In-flight settle correlator stored until oracle fulfill (or failure).
struct PendingSettle {
    address treasury;
    bytes32 tournamentId;
    uint16 season;
    uint32 roundNumber;
}

/// @notice Decoded public outputs from a successful `SettleDms` fulfill (fed into `finalizeRound`).
struct PbrSettleResult {
    address[] vaults;
    uint256[] mwPoints;
    uint256 adjTotalPoints;
}
