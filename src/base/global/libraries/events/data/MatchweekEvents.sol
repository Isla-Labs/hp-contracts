// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundFetchPhase, SeasonFetchStep } from "@types/data/RoundManagerTypes.sol";

library MatchweekEvents {
    event RoundUpserted(bytes32 indexed tournamentId, uint16 indexed seasonStartYear, uint32 roundNumber);

    /// @notice Fetch state machine armed (seasons ordered earliest → latest).
    event RoundFetchQueued(
        bytes32 indexed tournamentId, bytes32[] seasonIds, uint16[] seasonStartYears, RoundFetchPhase phase
    );

    /// @notice CVM round fetch opened (`HistoricalRoundSync`).
    event RoundScheduleRequested(
        bytes32 indexed requestId,
        bytes32 indexed tournamentId,
        bytes32 indexed seasonId,
        uint16 seasonStartYear,
        SeasonFetchStep step,
        uint32 cursor
    );

    event RoundFetchPhaseChanged(bytes32 indexed tournamentId, RoundFetchPhase previous, RoundFetchPhase next);

    event SeasonFetchStepChanged(
        bytes32 indexed tournamentId, bytes32 indexed seasonId, SeasonFetchStep previous, SeasonFetchStep next
    );

    event RoundOracleFailed(bytes32 indexed requestId, bytes32 indexed tournamentId, bytes err);

    /// @notice Permissionless live refresh kicked (`CvmJob.RoundSync`).
    event RoundRefreshQueued(bytes32 indexed tournamentId, bytes32 seasonId, uint16 seasonStartYear, bytes32 requestId);

    /// @notice Live calendar rollover opened a new registry season.
    event SeasonOpenedViaRefresh(
        bytes32 indexed tournamentId, bytes32 indexed seasonId, uint16 seasonStartYear, uint32 finalRound
    );
}
