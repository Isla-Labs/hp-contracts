// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IPbrSettle
 * @notice CVM `SettleDms` pipeline: treasury-gated kickoff → zk-verified fulfill → `finalizeRound`.
 */
interface IPbrSettle {
    /**
     * @notice Open a `CvmJob.SettleDms` request for a locked round.
     * @dev Callable only by `TournamentRegistry.getPbrTreasury(tournamentId)`.
     * @param tournamentId Tournament whose treasury is requesting settle.
     * @param season Season cursor (matches `PbrTreasury.seasonId` at request time).
     * @param roundNumber Active round being settled.
     * @param utilizedVaults Snapshotted utilized vaults (may be empty if no stakers).
     * @return requestId CVM correlator for the pending fulfill.
     */
    function settleRound(
        bytes32 tournamentId,
        uint16 season,
        uint32 roundNumber,
        address[] calldata utilizedVaults
    ) external returns (bytes32 requestId);

    function jobId(bytes32 tournamentId, uint16 season, uint32 roundNumber) external pure returns (bytes32);

    function pendingRequest(bytes32 id) external view returns (bytes32 requestId);
}
