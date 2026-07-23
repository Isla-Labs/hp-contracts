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
    error InvalidTournamentType(TournamentType actual, TournamentType expected);
    error UnsupportedTournamentType(TournamentType tournamentType);
    error EmptyHubs();
    error HubNotRegistered(bytes32 leagueId);
    error TournamentsExist(uint256 count);
    error VaultMissing(bytes32 playerId);
    error InvalidOpenSeasonData();
    error AddressMismatch(address actual, address expected);

    //  DopplerConfig
    error InvalidLaunchSupply();
    error InvalidTickSpacing();
    error EmptyCurves();
    error InvalidCurve();
    error InvalidCurveShares(uint256 totalShares);
    error InvalidFeeDistribution();
}
