// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { TournamentType } from "@base/global/types/TournamentTypes.sol";

library DeploymentsErrors {
    error ZeroAddress();
    error ZeroId();
    error ZeroSalt();
    error ZeroSeason();
    error Unauthorized();
    error NotConfigured();
    error InvalidTournamentType(TournamentType actual, TournamentType expected);
    error UnsupportedTournamentType(TournamentType tournamentType);
    error EmptyHubs();
    error HubNotRegistered(bytes32 leagueId);
    error TournamentsExist(uint256 count);
    error VaultMissing(bytes32 playerId);
    error InvalidOpenSeasonData();
    error AddressMismatch(address actual, address expected);
}
