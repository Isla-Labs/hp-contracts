// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IDopplerLocker
 * @notice Waiting-room intake for players cleared for Doppler market deploy.
 */
interface IDopplerLocker {
    /**
     * @notice Intake new `playerIds` under `seasonId` (calendar HPID) as `AwaitingMetadata`,
     *         promote `ReadyToQueue` → 24h `Queued`, and request PlayerMetadata for awaiting entries
     *         (one CVM request per distinct season).
     */
    function queueAssets(bytes32 seasonId, bytes32[] calldata playerIds) external;

    /**
     * @notice Remove a player from the queue during the 24h review window.
     */
    function unqueueAsset(bytes32 playerId) external;

    /**
     * @notice Manual name/symbol override during the 24h review window (re-arms `queuedAt`).
     */
    function editMetadata(bytes32 playerId, string calldata name, string calldata symbol) external;

    /**
     * @notice Request vanity salts for the first queue entry past the 24h wait (one player per call).
     */
    function deployAssets() external returns (bytes32 requestId);
}
