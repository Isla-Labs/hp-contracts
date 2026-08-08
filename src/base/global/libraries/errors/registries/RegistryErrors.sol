// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { TournamentType } from "@types/registries/TournamentTypes.sol";

library RegistryErrors {
    // --------------------------------------------
    //  Shared Errors
    // --------------------------------------------

    error ZeroAddress();
    error ZeroId();
    error Exists();
    error NotFound();
    error LengthMismatch();

    // --------------------------------------------
    //  PlayerSetRegistry Errors
    // --------------------------------------------

    error NotAuthorized();
    error VaultDataAlreadySet(bytes32 playerId);
    error AdvancedTradeDataAlreadySet(bytes32 playerId);
    error TournamentAlreadyActive(bytes32 tournamentId);
    error TournamentNotActive(bytes32 tournamentId);

    // --------------------------------------------
    //  TournamentRegistry Errors
    // --------------------------------------------

    error HubAlreadyRegistered(bytes32 leagueId);
    error HubNotRegistered(bytes32 leagueId);
    error HubAlreadyLinked(bytes32 tournamentId, bytes32 leagueId);
    error HubNotLinked(bytes32 tournamentId, bytes32 leagueId);
    error HubMismatch(bytes32 leagueId, address expected, address actual);
    error InvalidLinkTarget(TournamentType tournamentType);
    error SeasonExists(bytes32 tournamentId, uint16 seasonStartYear);
    error SeasonNotFound(bytes32 tournamentId, uint16 seasonStartYear);
    /// @dev Global reverse index: `seasonId` already opened under another tournament.
    error SeasonIdTaken(bytes32 seasonId, bytes32 existingTournamentId);
    error InvalidFinalRound();
    error RoundNotFound(bytes32 tournamentId, uint16 seasonStartYear, uint32 roundNumber);
    error InvalidRoundNumber(uint32 roundNumber, uint32 finalRound);
    error InvalidTimeRange(uint64 startTime, uint64 endTime);
    error VaultAlreadyRegistered(bytes32 tournamentId, address vault);
    error VaultNotRegistered(bytes32 tournamentId, address vault);
    error UnknownVault(address vault);
}
