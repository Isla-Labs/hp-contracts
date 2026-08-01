// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title PbrSettleTypes
 * @notice Types for the Phala ingest → Succinct prove → settle pipeline.
 */

/// @notice Lifecycle of one matchweek PBR settlement job.
enum PbrSettlePhase {
    None,
    /// @dev Ingest request open; waiting for DMS digest from Phala.
    IngestPending,
    /// @dev Digest committed; prove request open / ready.
    Ingested,
    /// @dev Prove-submit request open; waiting for Succinct `proofRequestId`.
    ProvePending,
    /// @dev Succinct job registered; settle request open / ready.
    ProveRequested,
    /// @dev Settle request open; waiting for proof + public values.
    SettlePending,
    /// @dev Proof verified and points recorded (treasury apply may follow).
    Settled,
    /// @dev Terminal failure (attestor `fail` or verify revert path).
    Failed
}

/// @notice Onchain record for a single (tournament, season, round) settlement job.
struct PbrSettleJob {
    PbrSettlePhase phase;
    bytes32 tournamentId;
    uint16 season;
    uint32 roundNumber;
    /// @notice Offchain source tag (e.g. StatsPerform feed id / fixture bundle id).
    bytes32 sourceId;
    /// @notice `keccak256` (or agreed hash) of pinned raw DMS.
    bytes32 digest;
    /// @notice Succinct network proof request id.
    bytes32 proofRequestId;
    /// @notice Pinned verification-key id allowed for this settle.
    bytes32 vkId;
    /// @notice Oracle2 request ids for each phase (correlation / debugging).
    bytes32 ingestRequestId;
    bytes32 proveRequestId;
    bytes32 settleRequestId;
    /// @notice Set when phase → Failed.
    bytes32 failReasonHash;
}

/// @notice Verified public outputs after phase-3 settle (fed into `PbrTreasury.settle`).
struct PbrSettleResult {
    address[] vaults;
    uint256[] mwPoints;
    uint256 adjTotalPoints;
    bool applied;
}
