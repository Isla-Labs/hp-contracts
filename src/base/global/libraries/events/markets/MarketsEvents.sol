// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PlayerStatus } from "@types/registries/PlayerSetTypes.sol";
import { TournamentType } from "@types/registries/TournamentTypes.sol";

library MarketsEvents {
    // --------------------------------------------
    //  FeeRouter Events
    // --------------------------------------------

    event FeeRouterCreated(bytes32 indexed playerId, address indexed feeRouter, address indexed pbrFeeHub);

    event PbrFeeHubUpdated(bytes32 indexed playerId, address indexed previousHub, address indexed newHub);
    event IntegratorUpdated(bytes32 indexed playerId, address indexed previous, address indexed integrator);
    event StatusUpdated(bytes32 indexed playerId, PlayerStatus previous, PlayerStatus status);
    event FeesRelayed(bytes32 indexed playerId, address indexed to, uint256 amount);
    event FeesQueued(bytes32 indexed playerId, address indexed to, uint256 amount);

    // --------------------------------------------
    //  PbrFeeHub Events
    // --------------------------------------------

    event PbrFeeHubCreated(bytes32 indexed leagueId, address indexed pbrFeeHub);

    event FeesReceived(uint256 amount);
    event FeesRelayed(TournamentType indexed tournamentType, address indexed treasury, uint256 amount);
    event FeesQueued(TournamentType indexed tournamentType, address indexed treasury, uint256 amount);
    /// @notice Retry of pending for a treasury no longer mapped to a bucket (no tournament type).
    event OrphanFeesRelayed(address indexed treasury, uint256 amount);
    event OrphanFeesQueued(address indexed treasury, uint256 amount);
    event TopLevelSplitUpdated(uint16 domesticBps, uint16 continentalBps, uint16 internationalBps);
    event LeagueShareUpdated(uint16 leagueShareBps);
    event LeagueTreasuryUpdated(address indexed previous, address indexed treasury);
    event DomesticCupsUpdated(address[] cups);
    event ContinentalUpdated(address[] treasuries);
    event InternationalUpdated(address[] treasuries);
    event InternationalActiveUpdated(bool active, address indexed treasury);
    event InternationalActiveShareUpdated(uint16 internationalActiveShareBps);
}
