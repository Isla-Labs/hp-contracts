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
    error OracleInFlight(bytes32 requestId);
    error UnknownOracleRequest(bytes32 requestId);
    error NothingReady();

    //  DopplerConfig
    error InvalidLaunchSupply();
    error InvalidTickSpacing();
    error EmptyCurves();
    error InvalidCurve();
    error InvalidCurveShares(uint256 totalShares);
    error InvalidFeeDistribution();
}
