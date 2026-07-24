// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Hub, RoundSchedule, Season, TournamentType } from "@types/TournamentTypes.sol";

/**
 * @title ITournamentRegistry
 * @notice Cross-contract surface for tournament topology, calendars, and vault membership SoT.
 */
interface ITournamentRegistry {
    // --------------------------------------------
    //  Domestic hubs — CATEGORY_ONE
    // --------------------------------------------

    function registerHub(Hub calldata hub) external;

    function pbrFeeHubOf(bytes32 leagueId) external view returns (address);

    // --------------------------------------------
    //  Tournament registration — CATEGORY_ONE
    // --------------------------------------------

    function createTournament(
        bytes32 tournamentId,
        TournamentType tournamentType,
        Hub[] calldata feeHubs,
        address pbrTreasury
    ) external;

    function linkHub(bytes32 tournamentId, Hub calldata hub) external;

    // --------------------------------------------
    //  Vault membership SoT — CATEGORY_ONE / TWO / THREE
    // --------------------------------------------

    /// @notice Register vaults for `tournamentId` and sync the treasury cache.
    function registerVaults(bytes32 tournamentId, address[] calldata vaults) external;

    /// @notice Unregister vaults for `tournamentId` and sync the treasury cache.
    function unregisterVaults(bytes32 tournamentId, address[] calldata vaults) external;

    // --------------------------------------------
    //  Season calendar — CATEGORY_THREE
    // --------------------------------------------

    function openSeason(bytes32 tournamentId, bytes32 seasonId, uint16 seasonStartYear, uint32 finalRound) external;

    function upsertRound(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule calldata round) external;

    function upsertRounds(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule[] calldata rounds) external;

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function tournamentCount() external view returns (uint256);

    function getAllDomesticPbrFeeHubs() external view returns (address[] memory hubs);

    /// @notice All registered domestic hubs as `(leagueId, pbrFeeHub)` pairs.
    function getAllDomesticHubs() external view returns (Hub[] memory hubs);

    function getTournamentsForLeague(bytes32 leagueId) external view returns (bytes32[] memory ids);

    function getPbrTreasury(bytes32 tournamentId) external view returns (address);

    function isVaultRegistered(bytes32 tournamentId, address vault) external view returns (bool);

    function getRegisteredVaults(bytes32 tournamentId) external view returns (address[] memory);

    function getFinalRound(bytes32 tournamentId, uint16 seasonStartYear) external view returns (uint32);

    function getSeasonId(bytes32 tournamentId, uint16 seasonStartYear) external view returns (bytes32);

    function getSeason(bytes32 tournamentId, uint16 seasonStartYear) external view returns (Season memory);

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

    function isRoundPublished(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (bool);
}
