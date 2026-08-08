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
    event VaultDataAdded(bytes32 indexed playerId, address playerVault, address stToken);
    event VaultDataUpdated(bytes32 indexed playerId, address playerVault, address stToken, bool isUtilized);
    event DopplerDataUpdated(bytes32 indexed playerId, address feeRouter);
    event AdvancedTradeDataAdded(bytes32 indexed playerId, address advancedTradeVault, address markSource);

    // --------------------------------------------
    //  TournamentRegistry Events
    // --------------------------------------------

    event HubRegistered(bytes32 indexed leagueId, address indexed pbrFeeHub);
    event HubUpdated(bytes32 indexed leagueId, address indexed previous, address indexed pbrFeeHub);
    event TournamentCreated(bytes32 indexed tournamentId, TournamentType tournamentType, address indexed pbrTreasury);
    /// @notice Domestic league tournament created — CRE squads Trigger 1 (historical bootstrap).
    /// @dev `leagueId == tournamentId` for `DOMESTIC_LEAGUE`. CRE syncs seasons into EligibilityStore.
    event DomesticLeagueCreated(bytes32 indexed leagueId, address indexed pbrTreasury);
    event HubAddedToTournament(bytes32 indexed tournamentId, bytes32 indexed leagueId, address pbrFeeHub);
    event HubRemovedFromTournament(bytes32 indexed tournamentId, bytes32 indexed leagueId);
    event PbrTreasuryUpdated(bytes32 indexed tournamentId, address indexed previous, address indexed pbrTreasury);
    event SeasonOpened(
        bytes32 indexed tournamentId, bytes32 indexed seasonId, uint16 indexed seasonStartYear, uint32 finalRound
    );
    /// @notice Domestic-league season opened — CRE squads sync/append (not cups / continental).
    /// @dev `leagueId == tournamentId` for `DOMESTIC_LEAGUE`. Generic `SeasonOpened` still fires for all types.
    event DomesticSeasonOpened(bytes32 indexed leagueId, bytes32 indexed seasonId, uint16 indexed seasonStartYear);
    event RoundUpserted(bytes32 indexed tournamentId, uint16 indexed seasonStartYear, uint32 roundNumber);
    event VaultRegistered(bytes32 indexed tournamentId, address indexed vault);
    event VaultUnregistered(bytes32 indexed tournamentId, address indexed vault);
}
