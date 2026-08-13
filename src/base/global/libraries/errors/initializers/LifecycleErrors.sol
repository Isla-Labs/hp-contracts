// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library LifecycleErrors {
    error ZeroAddress();
    error ZeroId();
    error Unauthorized();
    error AlreadySet();
    error NotConfigured();
    error LengthMismatch(uint256 left, uint256 right);

    error NothingReady();
    error NotQueued(bytes32 playerId);
    error BadQueueStatus(bytes32 playerId, uint8 actual);
    error OracleInFlight(bytes32 requestId);
    error UnknownOracleRequest(bytes32 requestId);

    /// @notice Player has no domestic `leagueId` on `PlayerSet.tournamentData`.
    error MissingLeagueId(bytes32 playerId);

    /// @notice No `FeeRouter` recorded on the player set (cannot verify hub routing).
    error MissingFeeRouter(bytes32 playerId);

    /// @notice Domestic hub not registered for `leagueId` in `TournamentRegistry`.
    error HubNotRegistered(bytes32 leagueId);

    /**
     * @notice `FeeRouter.pbrFeeHub` does not match `TournamentRegistry.pbrFeeHubOf(leagueId)`.
     * @dev Typical after a cross-league move if hub migration was skipped before reactivate.
     */
    error FeeHubMismatch(bytes32 playerId, bytes32 leagueId, address expected, address actual);
}
