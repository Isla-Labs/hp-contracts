// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IDopplerLocker
 * @notice Waiting-room intake for players cleared for Doppler market deploy.
 */
interface IDopplerLocker {
    /**
     * @notice Intake new `playerIds` under a domestic `leagueId` + calendar `seasonId`.
     * @dev Requires `TournamentRegistry.pbrFeeHubOf(leagueId)` (DeployTournament for that league first).
     *      Promotes `ReadyToQueue` → 24h `Queued` and requests PlayerMetadata (paginated by season).
     */
    function queueAssets(bytes32 leagueId, bytes32 seasonId, bytes32[] calldata playerIds) external;

    /**
     * @notice Remove a player from the queue (`Queued` review window or `DeployFailed`).
     */
    function unqueueAsset(bytes32 playerId) external;

    /**
     * @notice Manual name/symbol override during the 24h review window (re-arms `queuedAt`).
     * @dev Clears any prior IPFS URIs; they are set later by `CvmJob.FinalConfig`.
     */
    function editMetadata(bytes32 playerId, string calldata name, string calldata symbol) external;

    /**
     * @notice Kick the next deploy: resume a `DeployReady` entry, or request `FinalConfig` for a `Queued` one.
     * @return requestId CVM request id, or `bytes32(0)` when a `DeployReady` resume ran (no new oracle job).
     */
    function deployAssets() external returns (bytes32 requestId);

    /**
     * @notice Clear a `DeployFailed` entry after ops intervention.
     * @param keepSalts Resume as `DeployReady` when salts/URIs are still valid; else re-queue for FinalConfig.
     */
    function resetFailedDeploy(bytes32 playerId, bool keepSalts) external;
}
