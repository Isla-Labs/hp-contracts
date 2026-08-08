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
    error UnknownMarketPhase(bytes32 playerId, address hooks);

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

    /**
     * @notice An `activeTournament` is not linked to the player's current `leagueId`.
     * @dev Stale cups / prior-league tournaments must be cleared or remapped before reactivate.
     */
    error ActiveTournamentNotLinked(bytes32 playerId, bytes32 leagueId, bytes32 tournamentId);

    /// @notice Player vault is not registered on the domestic-league `PbrTreasury`.
    error VaultNotOnLeagueTreasury(bytes32 playerId, bytes32 leagueId, address treasury, address vault);

    /// @notice Player vault is not registered on an active tournament's `PbrTreasury`.
    error VaultNotOnTournamentTreasury(bytes32 playerId, bytes32 tournamentId, address treasury, address vault);
}
