// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Hub, RoundSchedule, TournamentType } from "@base/global/types/TournamentTypes.sol";

/**
 * @title ITournamentRegistry
 * @notice Cross-contract surface for tournament topology + season calendars.
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
    //  Season calendar — CATEGORY_THREE
    // --------------------------------------------

    function openSeason(bytes32 tournamentId, uint16 seasonStartYear, uint32 finalRound) external;

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

    function getFinalRound(bytes32 tournamentId, uint16 seasonStartYear) external view returns (uint32);

    function getRound(bytes32 tournamentId, uint16 seasonStartYear, uint32 roundNumber)
        external
        view
        returns (RoundSchedule memory);

    function isRoundPublished(bytes32 tournamentId, uint16 seasonStartYear, uint32 roundNumber)
        external
        view
        returns (bool);
}
