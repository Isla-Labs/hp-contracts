// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundStatus } from "@types/vaults/VaultTypes.sol";

library VaultsErrors {
    // --------------------------------------------
    //  Shared Errors
    // --------------------------------------------

    error ZeroAddress();
    error ZeroId();
    error Unauthorized();
    error NothingToClaim();

    // --------------------------------------------
    //  PBRTreasury Errors
    // --------------------------------------------

    error ZeroSeason();
    error LengthMismatch();
    error NothingDue();
    error NoFixtures();
    error UnknownFixture(bytes32 fixtureId);
    error FixtureAlreadySettled(bytes32 fixtureId);
    error TooManyPlayers(uint256 length);
    error BadRoundStatus(uint16 season, uint32 roundNumber, RoundStatus actual, RoundStatus expected);
    error RoundNotEnded(uint16 season, uint32 roundNumber, uint256 endTime, uint256 currentTime);
    error UnknownVault(address vault);
    error VaultAlreadyRegistered(address vault);
    error InsufficientRoundFunds();
    error TransferFailed();

    // --------------------------------------------
    //  PlayerVault Errors
    // --------------------------------------------

    error ZeroAmount();
    error VaultInactive();
    error OnlyTournamentTreasury();
    error InsufficientStake();
    error MatchweekLock();
    error RoundNotUtilized(bytes32 tournamentId, uint16 seasonId, uint32 roundNumber);
    error AlreadyClaimed();
    error UnknownTournamentTreasury(bytes32 tournamentId);

    // --------------------------------------------
    //  StakedToken Errors
    // --------------------------------------------

    error OnlyVault();

    // --------------------------------------------
    //  Factory Errors
    // --------------------------------------------

    error ZeroSalt();
    error InvalidSalt();
}
