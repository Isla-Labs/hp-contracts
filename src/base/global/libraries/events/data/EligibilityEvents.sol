// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Position } from "@types/registries/PlayerSetTypes.sol";
import { SeasonSquadStep, SquadFetchPhase } from "@types/data/SquadStoreTypes.sol";

library EligibilityEvents {
    event AppearancesRecorded(uint256 count);

    event MinutesUpdated(
        bytes32 indexed playerId,
        bytes32 indexed seasonId,
        uint32 indexed roundNumber,
        Position position,
        uint32 addedMins,
        uint32 cumulativeMins,
        Position expectedPosition
    );

    event WeightedScoreUpdated(bytes32 indexed playerId, bytes32 indexed leagueId, uint256 weightedScoreWad);

    /// @notice Career minutes flipped the player's modal position (strict beat; ties keep incumbent).
    event PlayerExpectedPositionChanged(bytes32 indexed playerId, Position previous, Position next);

    event SquadPlayerCreated(bytes32 indexed playerId, uint256 birthDate);

    /// @notice Deployed player queued to TransferLocker (continuity under-threshold).
    event PlayerDeactivated(bytes32 indexed playerId, uint32 effectiveMins);

    /// @notice `INACTIVE` player back above continuity → queued to TransferLocker for reactivate.
    event PlayerReactivateQueued(bytes32 indexed playerId, uint32 effectiveMins);

    /// @notice Daily-active club squad overwritten (`playerCount` = active roster size).
    event SquadListUpdated(bytes32 indexed clubId, uint256 playerCount);

    /// @notice Deployed player left the league (queued to TransferLocker after full sweep).
    event PlayerLeftLeague(bytes32 indexed playerId);

    /// @notice SORT upsert detected a club move (MinutesStore membership change).
    event PlayerClubChanged(bytes32 indexed playerId, bytes32 indexed previousClubId, bytes32 indexed newClubId);

    /// @notice SORT upsert detected a league move (MinutesStore membership change).
    event PlayerLeagueChanged(bytes32 indexed playerId, bytes32 previousLeagueId, bytes32 newLeagueId);

    /// @notice Governance updated deploy / continuity thresholds (`EligibilityCriteria`).
    event EligibilityThresholdsUpdated(
        uint32 thresholdGk,
        uint32 thresholdUnder21,
        uint32 thresholdOutfield,
        uint32 thresholdNewTransfer,
        uint256 under21Age
    );

    /// @notice League squad machine armed (seasons ordered earliest → latest).
    event SquadFetchQueued(
        bytes32 indexed leagueId, bytes32[] seasonIds, uint16[] seasonStartYears, SquadFetchPhase phase
    );

    event SquadFetchPhaseChanged(bytes32 indexed leagueId, SquadFetchPhase previous, SquadFetchPhase next);

    event SeasonSquadStepChanged(
        bytes32 indexed leagueId, bytes32 indexed seasonId, SeasonSquadStep previous, SeasonSquadStep next
    );

    /// @notice CVM squad job opened (`HistoricalSquadSync` / `SquadSync`).
    event SquadOracleRequested(
        bytes32 indexed requestId,
        bytes32 indexed leagueId,
        bytes32 indexed seasonId,
        uint16 seasonStartYear,
        SeasonSquadStep step,
        uint32 cursor,
        uint16 personsOffset
    );

    /// @notice Historical squad bootstrap requested by Orchestrator / Verifier.
    event SquadDataRequested(
        bytes32 indexed tournamentId, bytes32[] seasonIds, uint16[] seasonStartYears, bytes32 requestId
    );

    /// @notice CVM fulfill returned `err` (pending cleared; retry by re-opening request).
    event SquadOracleFailed(bytes32 indexed requestId, bytes32 indexed leagueId, bytes err);

    /// @notice Permissionless live squad refresh kicked (`CvmJob.SquadSync`).
    event SquadRefreshQueued(bytes32 indexed leagueId, bytes32 seasonId, uint16 seasonStartYear, bytes32 requestId);

    /// @notice RoundManager adopted a newly opened season onto the Live cursor.
    event SeasonAdopted(bytes32 indexed leagueId, bytes32 indexed seasonId, uint16 seasonStartYear);
}
