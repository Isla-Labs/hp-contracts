// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Appearance } from "@types/data/PbrHistoricalTypes.sol";
import { SeasonRef } from "@types/data/RoundManagerTypes.sol";
import {
    LeagueSquadFetch,
    MinutesStore,
    SquadFetchPhase,
    SquadList,
    VerifySnapshot
} from "@types/data/SquadStoreTypes.sol";

/**
 * @title ISquadStore
 * @notice Squad ingest SoT + historical/live fetch machine + verify page helpers.
 */
interface ISquadStore {
    /**
     * @notice Arm historical → live squad fetch for `leagueId` (seasons earliest → latest).
     * @dev Orchestrator-only (paired with `RoundManager.openTournament` on createTournament).
     */
    function openLeague(
        bytes32 leagueId,
        bytes32[] calldata seasonIds,
        uint16[] calldata seasonStartYears
    ) external returns (bytes32 requestId);

    /// @notice Permissionless live squad refresh for the latest season (rate-limited, default 1h).
    function refreshSquads(bytes32 leagueId) external returns (bytes32 requestId);

    /**
     * @notice Append a newly opened season (RoundManager live rollover). Pins Live cursor to latest.
     * @dev Does not open an oracle request — call `refreshSquads` afterward.
     */
    function adoptSeason(bytes32 leagueId, bytes32 seasonId, uint16 seasonStartYear) external;

    function recordAppearances(bytes32 seasonId, uint16 seasonStartYear, Appearance[] calldata appearances) external;

    function getFetchState(bytes32 leagueId) external view returns (LeagueSquadFetch memory);

    function getLatestSeason(bytes32 leagueId) external view returns (SeasonRef memory);

    function getFetchPhase(bytes32 leagueId) external view returns (SquadFetchPhase);

    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory);

    function getSquadList(bytes32 clubId) external view returns (SquadList memory);

    function getVerifySnapshot(bytes32 playerId) external view returns (VerifySnapshot memory);

    function playerCount() external view returns (uint256);

    function playerIdAt(uint256 index) external view returns (bytes32);

    function playerIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory);

    /// @dev Verifier-only: GC stale deactivated rows (swap-remove). Returns true if purged.
    function purgeIfStale(uint256 index) external returns (bool purged);

    /// @dev Verifier-only: idle-decay current-league score to `G_now`, return lean snapshot.
    function syncAndSnapshot(bytes32 playerId) external returns (VerifySnapshot memory);

    function takePendingLeftLeague() external returns (bytes32[] memory);

    function takePendingClubChanged() external returns (bytes32[] memory);

    function takePendingLeagueChanged() external returns (bytes32[] memory);
}
