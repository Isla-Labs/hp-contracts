// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { TournamentType } from "@types/registries/TournamentTypes.sol";
import { LifecycleReason } from "@types/initializers/LifecycleTypes.sol";

/**
 * @title OrchestratorEvents
 * @notice Named-flow telemetry for `src/Orchestrator.sol` (Phase A historical fetch = events only).
 */
library OrchestratorEvents {
    /// @notice Topology bootstrap finished; historical fetch intents emitted separately.
    event TournamentFlowDeployed(
        bytes32 indexed tournamentId,
        TournamentType tournamentType,
        address indexed pbrTreasury,
        address pbrFeeHub,
        uint256 seasonCount
    );

    /// @notice Round bootstrap queued on RoundManager (seasons include start years).
    event HistoricalRoundFetchQueued(
        bytes32 indexed tournamentId, bytes32[] seasonIds, uint16[] seasonStartYears, bytes32 requestId
    );

    /// @notice Squad bootstrap queued (domestic leagues; seasons include start years).
    event HistoricalSquadFetchQueued(
        bytes32 indexed tournamentId, bytes32[] seasonIds, uint16[] seasonStartYears, bytes32 requestId
    );

    event MarketQueued(bytes32 indexed leagueId, bytes32 indexed seasonId, uint256 playerCount);

    event MarketDeployKicked(bytes32 indexed requestId);

    event LifecycleEnqueued(bytes32 indexed playerId, LifecycleReason reason);

    event LifecycleProcessKicked(bytes32 indexed requestId);
}
