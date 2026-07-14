// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/access/Ownable2Step.sol";

import {
    ActiveMatchweek,
    LeagueData,
    MatchweekInfo,
    Season
} from "@base/global/types/TournamentTypes.sol";

/**
 * @title TournamentRegistry
 * @notice Canonizes league / season / matchweek state (`LeagueData`) for PBR + PPM flows.
 * @dev Owner (ops / timelock) writes league structure and publishes active matchweek windows
 *      plus `fixtureUuids[]` at matchweek start (`trustlessPpm.md`).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TournamentRegistry is Ownable2Step {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    mapping(bytes32 leagueId => LeagueData data) private _leagues;
    bytes32[] private _leagueIds;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    event LeagueCreated(bytes32 indexed leagueId, address indexed pbrTreasury);
    event PbrTreasuryUpdated(bytes32 indexed leagueId, address indexed pbrTreasury);
    event MatchweekInfoUpdated(
        bytes32 indexed leagueId, uint16 activeMatchweek, uint256 unixStartTime, uint256 unixEndTime
    );
    event FixtureUuidsPublished(bytes32 indexed leagueId, uint16 activeMatchweek, uint256 count);
    event SeasonAdded(bytes32 indexed leagueId, bytes32 indexed seasonId, uint256 seasonIndex);
    event SeasonUpdated(bytes32 indexed leagueId, uint256 seasonIndex, bytes32 indexed seasonId);

    error ZeroAddress();
    error ZeroId();
    error LeagueAlreadyExists();
    error UnknownLeague();
    error InvalidWindow();
    error InvalidSeasonIndex();
    error LeagueIdMismatch();

    // --------------------------------------------
    //  Init
    // --------------------------------------------

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    // --------------------------------------------
    //  League lifecycle
    // --------------------------------------------

    /**
     * @notice Creates a league shell with treasury + initial matchweek info (no seasons yet).
     */
    function createLeague(bytes32 leagueId, address pbrTreasury, MatchweekInfo calldata matchweekInfo)
        external
        onlyOwner
    {
        if (leagueId == bytes32(0)) revert ZeroId();
        if (pbrTreasury == address(0)) revert ZeroAddress();
        if (_leagues[leagueId].leagueId != bytes32(0)) revert LeagueAlreadyExists();
        _validateWindow(matchweekInfo.activeMatchweek.unixStartTime, matchweekInfo.activeMatchweek.unixEndTime);

        LeagueData storage league = _leagues[leagueId];
        league.leagueId = leagueId;
        league.pbrTreasury = pbrTreasury;
        _copyMatchweekInfo(league.matchweekInfo, matchweekInfo);
        _leagueIds.push(leagueId);

        emit LeagueCreated(leagueId, pbrTreasury);
        emit MatchweekInfoUpdated(
            leagueId,
            matchweekInfo.activeMatchweek.activeMatchweek,
            matchweekInfo.activeMatchweek.unixStartTime,
            matchweekInfo.activeMatchweek.unixEndTime
        );
        if (matchweekInfo.activeMatchweek.fixtureUuids.length > 0) {
            emit FixtureUuidsPublished(
                leagueId,
                matchweekInfo.activeMatchweek.activeMatchweek,
                matchweekInfo.activeMatchweek.fixtureUuids.length
            );
        }
    }

    /**
     * @notice Full replace of league data (including seasons tree). `data.leagueId` must match.
     */
    function setLeagueData(bytes32 leagueId, LeagueData calldata data) external onlyOwner {
        if (leagueId == bytes32(0)) revert ZeroId();
        if (data.leagueId != leagueId) revert LeagueIdMismatch();
        if (data.pbrTreasury == address(0)) revert ZeroAddress();
        _validateWindow(data.matchweekInfo.activeMatchweek.unixStartTime, data.matchweekInfo.activeMatchweek.unixEndTime);

        bool isNew = _leagues[leagueId].leagueId == bytes32(0);
        _leagues[leagueId] = data;
        if (isNew) _leagueIds.push(leagueId);

        emit LeagueCreated(leagueId, data.pbrTreasury);
        emit MatchweekInfoUpdated(
            leagueId,
            data.matchweekInfo.activeMatchweek.activeMatchweek,
            data.matchweekInfo.activeMatchweek.unixStartTime,
            data.matchweekInfo.activeMatchweek.unixEndTime
        );
    }

    function setPbrTreasury(bytes32 leagueId, address pbrTreasury) external onlyOwner {
        if (pbrTreasury == address(0)) revert ZeroAddress();
        LeagueData storage league = _requireLeague(leagueId);
        league.pbrTreasury = pbrTreasury;
        emit PbrTreasuryUpdated(leagueId, pbrTreasury);
    }

    function setMatchweekInfo(bytes32 leagueId, MatchweekInfo calldata matchweekInfo) external onlyOwner {
        LeagueData storage league = _requireLeague(leagueId);
        _validateWindow(matchweekInfo.activeMatchweek.unixStartTime, matchweekInfo.activeMatchweek.unixEndTime);
        _copyMatchweekInfo(league.matchweekInfo, matchweekInfo);

        emit MatchweekInfoUpdated(
            leagueId,
            matchweekInfo.activeMatchweek.activeMatchweek,
            matchweekInfo.activeMatchweek.unixStartTime,
            matchweekInfo.activeMatchweek.unixEndTime
        );
        if (matchweekInfo.activeMatchweek.fixtureUuids.length > 0) {
            emit FixtureUuidsPublished(
                leagueId,
                matchweekInfo.activeMatchweek.activeMatchweek,
                matchweekInfo.activeMatchweek.fixtureUuids.length
            );
        }
    }

    /**
     * @notice Publishes / replaces `fixtureUuids` for the active matchweek (matchweek start).
     */
    function setFixtureUuids(bytes32 leagueId, bytes32[] calldata fixtureUuids) external onlyOwner {
        LeagueData storage league = _requireLeague(leagueId);
        delete league.matchweekInfo.activeMatchweek.fixtureUuids;
        for (uint256 i; i < fixtureUuids.length; ++i) {
            league.matchweekInfo.activeMatchweek.fixtureUuids.push(fixtureUuids[i]);
        }
        emit FixtureUuidsPublished(leagueId, league.matchweekInfo.activeMatchweek.activeMatchweek, fixtureUuids.length);
    }

    function addSeason(bytes32 leagueId, Season calldata season) external onlyOwner {
        if (season.seasonId == bytes32(0)) revert ZeroId();
        LeagueData storage league = _requireLeague(leagueId);
        league.seasons.push(season);
        emit SeasonAdded(leagueId, season.seasonId, league.seasons.length - 1);
    }

    function setSeason(bytes32 leagueId, uint256 seasonIndex, Season calldata season) external onlyOwner {
        if (season.seasonId == bytes32(0)) revert ZeroId();
        LeagueData storage league = _requireLeague(leagueId);
        if (seasonIndex >= league.seasons.length) revert InvalidSeasonIndex();
        league.seasons[seasonIndex] = season;
        emit SeasonUpdated(leagueId, seasonIndex, season.seasonId);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function getLeagueData(bytes32 leagueId) external view returns (LeagueData memory) {
        return _leagues[leagueId];
    }

    function exists(bytes32 leagueId) external view returns (bool) {
        return _leagues[leagueId].leagueId != bytes32(0);
    }

    function getMatchweekInfo(bytes32 leagueId) external view returns (MatchweekInfo memory) {
        return _requireLeague(leagueId).matchweekInfo;
    }

    function getActiveMatchweek(bytes32 leagueId) external view returns (ActiveMatchweek memory) {
        return _requireLeague(leagueId).matchweekInfo.activeMatchweek;
    }

    function getFixtureUuids(bytes32 leagueId) external view returns (bytes32[] memory) {
        return _requireLeague(leagueId).matchweekInfo.activeMatchweek.fixtureUuids;
    }

    function getPbrTreasury(bytes32 leagueId) external view returns (address) {
        return _requireLeague(leagueId).pbrTreasury;
    }

    function seasonCount(bytes32 leagueId) external view returns (uint256) {
        return _requireLeague(leagueId).seasons.length;
    }

    function getSeason(bytes32 leagueId, uint256 seasonIndex) external view returns (Season memory) {
        LeagueData storage league = _requireLeague(leagueId);
        if (seasonIndex >= league.seasons.length) revert InvalidSeasonIndex();
        return league.seasons[seasonIndex];
    }

    function leagueCount() external view returns (uint256) {
        return _leagueIds.length;
    }

    function leagueIdAt(uint256 index) external view returns (bytes32) {
        return _leagueIds[index];
    }

    function leagueIds() external view returns (bytes32[] memory) {
        return _leagueIds;
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _requireLeague(bytes32 leagueId) internal view returns (LeagueData storage league) {
        league = _leagues[leagueId];
        if (league.leagueId == bytes32(0)) revert UnknownLeague();
    }

    function _validateWindow(uint256 start, uint256 end) internal pure {
        if (end != 0 && start != 0 && end <= start) revert InvalidWindow();
    }

    function _copyMatchweekInfo(MatchweekInfo storage dest, MatchweekInfo calldata src) internal {
        dest.tradingMatchweek = src.tradingMatchweek;
        dest.totalMatchweeks = src.totalMatchweeks;
        dest.activeMatchweek.activeMatchweek = src.activeMatchweek.activeMatchweek;
        dest.activeMatchweek.unixStartTime = src.activeMatchweek.unixStartTime;
        dest.activeMatchweek.unixEndTime = src.activeMatchweek.unixEndTime;

        delete dest.activeMatchweek.fixtureUuids;
        uint256 n = src.activeMatchweek.fixtureUuids.length;
        for (uint256 i; i < n; ++i) {
            dest.activeMatchweek.fixtureUuids.push(src.activeMatchweek.fixtureUuids[i]);
        }
    }
}
