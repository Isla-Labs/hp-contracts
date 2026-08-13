// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PlayerStatus } from "@types/registries/PlayerSetTypes.sol";
import { TournamentType } from "@types/registries/TournamentTypes.sol";

library RegistryEvents {
    // --------------------------------------------
    //  PlayerSetRegistry Events
    // --------------------------------------------

    event PlayerRegistered(bytes32 indexed playerId, address indexed token, address indexed feeRouter);
    event StatusUpdated(bytes32 indexed playerId, PlayerStatus status);
    event LeagueIdUpdated(bytes32 indexed playerId, bytes32 indexed leagueId);
    event ActiveTournamentAdded(bytes32 indexed playerId, bytes32 indexed tournamentId);
    event ActiveTournamentRemoved(bytes32 indexed playerId, bytes32 indexed tournamentId);
    /// @notice Emitted from `addPlayerSet` (vault is required at registration).
    event VaultDataAdded(bytes32 indexed playerId, address playerVault, address stToken);
    event VaultDataUpdated(bytes32 indexed playerId, address playerVault, address stToken, bool isUtilized);
    /// @notice `DopplerData.activePool` updated (hooks / feeRouter stay immutable after register).
    event ActivePoolUpdated(bytes32 indexed playerId);
    event AdvancedTradeDataAdded(bytes32 indexed playerId, address advancedTradeVault, address markSource);

    // --------------------------------------------
    //  TournamentRegistry Events
    // --------------------------------------------

    event HubRegistered(bytes32 indexed leagueId, address indexed pbrFeeHub);
    event TournamentCreated(bytes32 indexed tournamentId, TournamentType tournamentType, address indexed pbrTreasury);
    event HubAddedToTournament(bytes32 indexed tournamentId, bytes32 indexed leagueId, address pbrFeeHub);
    event SeasonOpened(
        bytes32 indexed tournamentId, bytes32 indexed seasonId, uint16 indexed seasonStartYear, uint32 finalRound
    );
    event RoundUpserted(bytes32 indexed tournamentId, uint16 indexed seasonStartYear, uint32 roundNumber);
    event VaultRegistered(bytes32 indexed tournamentId, address indexed vault);
    event VaultUnregistered(bytes32 indexed tournamentId, address indexed vault);
    /// @notice Unregister deferred while treasury active round is `Locked` (flushed after settle).
    event VaultUnregisterPending(bytes32 indexed tournamentId, address indexed vault);
    event VaultUnregisterFlushed(bytes32 indexed tournamentId, uint256 count);
}
