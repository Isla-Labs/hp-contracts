// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Hub, RoundSchedule, Season, TournamentType } from "@types/registries/TournamentTypes.sol";

/**
 * @title ITournamentRegistry
 * @notice Cross-contract surface for tournament topology, season calendars, and vault membership SoT.
 */
interface ITournamentRegistry {
    // --------------------------------------------
    //  Domestic hubs — owner (Orchestrator)
    // --------------------------------------------

    function registerHub(Hub calldata hub) external;

    function pbrFeeHubOf(bytes32 leagueId) external view returns (address);

    // --------------------------------------------
    //  Tournament registration — owner (Orchestrator)
    // --------------------------------------------

    function createTournament(
        bytes32 tournamentId,
        TournamentType tournamentType,
        Hub[] calldata feeHubs,
        address pbrTreasury
    ) external;

    function linkHub(bytes32 tournamentId, Hub calldata hub) external;

    // --------------------------------------------
    //  Vault membership SoT — owner (Orchestrator)
    // --------------------------------------------

    /// @notice Register vaults for `tournamentId`; sync treasury, vault cache, PSR index.
    /// @dev Cancels a deferred unregister if the vault was pending removal during `Locked`.
    function registerVaults(bytes32 tournamentId, address[] calldata vaults) external;

    /**
     * @notice Unregister vaults for `tournamentId`; sync treasury, vault cache, PSR index.
     * @dev If the tournament treasury's active round is `Locked`, removal is deferred until
     *      `flushPendingUnregisters` (called from `PbrTreasury.settle`) so SettlePbr still
     *      sees the vault in `getRegisteredVaults` / treasury `isVault` through distribute.
     *      PSR index is updated on actual unregister (immediate or flush), not while pending.
     */
    function unregisterVaults(bytes32 tournamentId, address[] calldata vaults) external;

    /// @notice Apply deferred unregisters after settle (`Claimable`). Callable by treasury or owner.
    function flushPendingUnregisters(bytes32 tournamentId) external;

    // --------------------------------------------
    //  Season calendar — owner (Orchestrator)
    // --------------------------------------------

    /// @notice Open a season with `finalRound`; rounds filled later via `upsertRound(s)`.
    function openSeason(bytes32 tournamentId, bytes32 seasonId, uint16 seasonStartYear, uint32 finalRound) external;

    function upsertRound(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule calldata round) external;

    function upsertRounds(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule[] calldata rounds) external;

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function tournamentCount() external view returns (uint256);

    /// @notice True when `createTournament` has registered `tournamentId` (non-reverting).
    function tournamentExists(bytes32 tournamentId) external view returns (bool);

    /**
     * @notice Reverse index: calendar `seasonId` → owning `tournamentId` (set in `openSeason`).
     * @dev For `DOMESTIC_LEAGUE`, `tournamentId == leagueId`. Zero if the season was never opened.
     */
    function tournamentIdOfSeason(bytes32 seasonId) external view returns (bytes32);

    function getAllDomesticPbrFeeHubs() external view returns (address[] memory hubs);

    /// @notice All registered domestic hubs as `(leagueId, pbrFeeHub)` pairs.
    function getAllDomesticHubs() external view returns (Hub[] memory hubs);

    function getTournamentsForLeague(bytes32 leagueId) external view returns (bytes32[] memory ids);

    function getPbrTreasury(bytes32 tournamentId) external view returns (address);

    function isVaultRegistered(bytes32 tournamentId, address vault) external view returns (bool);

    function isVaultUnregisterPending(bytes32 tournamentId, address vault) external view returns (bool);

    function getRegisteredVaults(bytes32 tournamentId) external view returns (address[] memory);

    /**
     * @notice True if `leagueId` is the domestic tournament itself or listed on its `feeHubs`.
     * @dev Used to validate TransferLocker oracle `activeTournamentIds` against `newLeagueId`.
     */
    function isLeagueLinkedToTournament(bytes32 tournamentId, bytes32 leagueId) external view returns (bool);

    function getFinalRound(bytes32 tournamentId, uint16 seasonStartYear) external view returns (uint32);

    function getSeasonId(bytes32 tournamentId, uint16 seasonStartYear) external view returns (bytes32);

    function getSeason(bytes32 tournamentId, uint16 seasonStartYear) external view returns (Season memory);

    /// @notice Seasons under one tournament, oldest `seasonStartYear` first (CRE RunBook sync).
    function getSeasonsOldestFirst(bytes32 tournamentId)
        external
        view
        returns (bytes32[] memory seasonIds, uint16[] memory seasonStartYears);

    /// @notice All SP tournament calendar ids (`tmcl`) with start years, oldest `seasonStartYear` first.
    function getSeasonIdsOldestFirst()
        external
        view
        returns (bytes32[] memory seasonIds, uint16[] memory seasonStartYears);

    function getRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (RoundSchedule memory);

    /// @notice True when the round exists with a valid time range and at least one fixture.
    function isRoundPublished(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (bool);
}
