// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { TournamentType } from "@types/TournamentTypes.sol";

library DeploymentsErrors {
    error ZeroAddress();
    error ZeroId();
    error ZeroSalt();
    error ZeroSeason();
    error Unauthorized();
    error AlreadySet();
    error NotConfigured();
    error ExecutionFailed(address target, bytes reason);
    error InvalidTournamentType(TournamentType actual, TournamentType expected);
    error UnsupportedTournamentType(TournamentType tournamentType);
    error EmptyHubs();
    error HubNotRegistered(bytes32 leagueId);
    error TournamentsExist(uint256 count);
    error VaultMissing(bytes32 playerId);
    error InvalidOpenSeasonData();
    error SaltMineExhausted(uint256 maxAttempts);
    error InvalidDN404Unit();

    //  DopplerLocker
    error LengthMismatch(uint256 left, uint256 right);
    error AlreadyQueued(bytes32 playerId);
    error NotQueued(bytes32 playerId);
    error BadQueueStatus(bytes32 playerId, uint8 actual);
    error MetadataNotSet(bytes32 playerId);
    error EmptyName();
    error EmptySymbol();
    error TooManyPlayers(uint256 max);
    error OracleInFlight(bytes32 requestId);
    error UnknownOracleRequest(bytes32 requestId);
    error NothingReady();
    error DeployAddressMismatch(address expected, address actual);
    /// @dev Predicted token exists but is not our Airlock market (salt frontrun / foreign create).
    error SaltOccupied(address token);
    error LeagueMismatch(bytes32 expected, bytes32 actual);
    /// @dev `seasonId` is not open on TournamentRegistry (or not under `leagueId`).
    error SeasonNotRegistered(bytes32 seasonId);

    //  DopplerConfig
    error InvalidLaunchSupply();
    error InvalidTickSpacing();
    error EmptyCurves();
    error InvalidCurve();
    error InvalidCurveShares(uint256 totalShares);
    error InvalidFeeDistribution();

    //  StakeVesting
    error ZeroAmount();
    error TransferFailed();
    error EmptyBeneficiaries();
    error InvalidBeneficiaryShares();
    error NothingToUnlock();
    error InsufficientExcessReserve();
}
