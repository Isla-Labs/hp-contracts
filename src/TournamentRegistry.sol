// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import {
    League,
    Continental,
    International,
    RoundSchedule,
    CupSeasonMeta
} from "@base/global/types/TournamentTypes.sol";

/**
 * @title TournamentRegistry
 * @notice Competition topology, cup→treasury bindings, and season-keyed round schedules.
 * @dev Fee path: FeeRouter → per-league `pbrFeeHub` → typed `PbrTreasury` destinations
 *      (domestic / continental / international cups). Continental and international
 *      topology here is calendar-only — they do not own fee hubs.
 *
 *      A round is **published** (lockable) only when:
 *        `startTime != 0 && endTime > startTime && fixtureIds.length > 0`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TournamentRegistry is Initializable, AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    bytes32 public constant CONTINENTAL_ID = keccak256("CONTINENTAL");
    bytes32 public constant INTERNATIONAL_ID = keccak256("INTERNATIONAL");

    mapping(bytes32 leagueId => League) private _leagues;
    bytes32[] private _leagueIds;

    Continental private _continental;
    International private _international;

    /// @notice Globally unique cupId → PbrTreasury
    mapping(bytes32 cupId => address) public cupPbrTreasury;

    /// @notice cupId → competition root (leagueId / CONTINENTAL_ID / INTERNATIONAL_ID)
    mapping(bytes32 cupId => bytes32) public cupCompetitionId;

    mapping(bytes32 competitionId => mapping(bytes32 cupId => mapping(uint16 seasonId => CupSeasonMeta))) private
        _seasonMeta;

    mapping(
        bytes32 competitionId
            => mapping(bytes32 cupId => mapping(uint16 seasonId => mapping(uint32 roundNumber => RoundSchedule)))
    ) private _rounds;

    event LeagueCreated(bytes32 indexed leagueId, address indexed pbrFeeHub);
    event ContinentalCreated();
    event InternationalCreated();

    event CupAdded(
        bytes32 indexed competitionId, bytes32 indexed cupId, address indexed pbrTreasury, uint256 cupIndex
    );
    event CupTreasuryUpdated(bytes32 indexed cupId, address indexed previous, address indexed pbrTreasury);

    event SeasonOpened(bytes32 indexed competitionId, bytes32 indexed cupId, uint16 indexed seasonId, uint32 finalRound);
    event RoundUpserted(
        bytes32 indexed competitionId, bytes32 indexed cupId, uint16 indexed seasonId, uint32 roundNumber
    );
    event RoundTimesUpdated(
        bytes32 indexed competitionId,
        bytes32 indexed cupId,
        uint16 indexed seasonId,
        uint32 roundNumber,
        uint64 startTime,
        uint64 endTime
    );
    event RoundFixturesUpdated(
        bytes32 indexed competitionId,
        bytes32 indexed cupId,
        uint16 indexed seasonId,
        uint32 roundNumber,
        uint256 fixtureCount
    );

    error ZeroAddress();
    error ZeroId();
    error LeagueAlreadyExists(bytes32 leagueId);
    error LeagueDoesNotExist(bytes32 leagueId);
    error ContinentalAlreadyExists();
    error ContinentalDoesNotExist();
    error InternationalAlreadyExists();
    error InternationalDoesNotExist();
    error CupAlreadyExists(bytes32 competitionId, bytes32 cupId);
    error CupIdNotFound(bytes32 competitionId, bytes32 cupId);
    error CupTreasuryAlreadySet(bytes32 cupId, address treasury);
    error SeasonNotOpen(bytes32 competitionId, bytes32 cupId, uint16 seasonId);
    error SeasonAlreadyOpen(bytes32 competitionId, bytes32 cupId, uint16 seasonId);
    error InvalidFinalRound();
    error InvalidRoundNumber(uint32 roundNumber, uint32 finalRound);
    error InvalidTimeRange(uint64 startTime, uint64 endTime);
    error RoundDoesNotExist(bytes32 competitionId, bytes32 cupId, uint16 seasonId, uint32 roundNumber);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(ADMIN_ROLE, admin);
    }

    // --------------------------------------------
    //  Topology
    // --------------------------------------------

    function createLeague(bytes32 leagueId, address pbrFeeHub) external onlyRole(ADMIN_ROLE) {
        if (leagueId == bytes32(0)) revert ZeroId();
        if (pbrFeeHub == address(0)) revert ZeroAddress();
        if (_leagues[leagueId].pbrFeeHub != address(0)) revert LeagueAlreadyExists(leagueId);

        _leagues[leagueId].pbrFeeHub = pbrFeeHub;
        _leagueIds.push(leagueId);
        emit LeagueCreated(leagueId, pbrFeeHub);
    }

    function addLeagueCup(bytes32 leagueId, bytes32 cupId, address pbrTreasury) external onlyRole(ADMIN_ROLE) {
        League storage league = _requireLeague(leagueId);
        _addCup(leagueId, league.cupIds, cupId, pbrTreasury);
    }

    function createContinental() external onlyRole(ADMIN_ROLE) {
        if (_continental.registered) revert ContinentalAlreadyExists();
        _continental.registered = true;
        emit ContinentalCreated();
    }

    function addContinentalCup(bytes32 cupId, address pbrTreasury) external onlyRole(ADMIN_ROLE) {
        if (!_continental.registered) revert ContinentalDoesNotExist();
        _addCup(CONTINENTAL_ID, _continental.cupIds, cupId, pbrTreasury);
    }

    function createInternational() external onlyRole(ADMIN_ROLE) {
        if (_international.registered) revert InternationalAlreadyExists();
        _international.registered = true;
        emit InternationalCreated();
    }

    function addInternationalCup(bytes32 cupId, address pbrTreasury) external onlyRole(ADMIN_ROLE) {
        if (!_international.registered) revert InternationalDoesNotExist();
        _addCup(INTERNATIONAL_ID, _international.cupIds, cupId, pbrTreasury);
    }

    function setCupPbrTreasury(bytes32 cupId, address pbrTreasury) external onlyRole(ADMIN_ROLE) {
        if (cupId == bytes32(0)) revert ZeroId();
        if (pbrTreasury == address(0)) revert ZeroAddress();
        if (cupCompetitionId[cupId] == bytes32(0)) revert CupIdNotFound(bytes32(0), cupId);

        address previous = cupPbrTreasury[cupId];
        cupPbrTreasury[cupId] = pbrTreasury;
        emit CupTreasuryUpdated(cupId, previous, pbrTreasury);
    }

    // --------------------------------------------
    //  Season calendar
    // --------------------------------------------

    function openSeason(bytes32 competitionId, bytes32 cupId, uint16 seasonId, uint32 finalRound)
        external
        onlyRole(ADMIN_ROLE)
    {
        _requireCup(competitionId, cupId);
        if (seasonId == 0 || finalRound == 0) revert InvalidFinalRound();

        CupSeasonMeta storage meta = _seasonMeta[competitionId][cupId][seasonId];
        if (meta.finalRound != 0) revert SeasonAlreadyOpen(competitionId, cupId, seasonId);

        meta.finalRound = finalRound;
        emit SeasonOpened(competitionId, cupId, seasonId, finalRound);
    }

    function upsertRound(bytes32 competitionId, bytes32 cupId, uint16 seasonId, RoundSchedule calldata round)
        external
        onlyRole(ADMIN_ROLE)
    {
        CupSeasonMeta storage meta = _requireSeason(competitionId, cupId, seasonId);
        if (round.roundNumber == 0 || round.roundNumber > meta.finalRound) {
            revert InvalidRoundNumber(round.roundNumber, meta.finalRound);
        }
        if (round.startTime != 0 || round.endTime != 0) {
            _validateTimeRange(round.startTime, round.endTime);
        }

        RoundSchedule storage stored = _rounds[competitionId][cupId][seasonId][round.roundNumber];
        if (stored.roundNumber == 0) {
            unchecked {
                ++meta.roundCount;
            }
        }

        stored.roundNumber = round.roundNumber;
        stored.startTime = round.startTime;
        stored.endTime = round.endTime;
        delete stored.fixtureIds;
        uint256 n = round.fixtureIds.length;
        for (uint256 i; i < n; ++i) {
            stored.fixtureIds.push(round.fixtureIds[i]);
        }

        emit RoundUpserted(competitionId, cupId, seasonId, round.roundNumber);
    }

    function updateRoundTimes(
        bytes32 competitionId,
        bytes32 cupId,
        uint16 seasonId,
        uint32 roundNumber,
        uint64 startTime,
        uint64 endTime
    ) external onlyRole(ADMIN_ROLE) {
        RoundSchedule storage round = _requireRound(competitionId, cupId, seasonId, roundNumber);
        if (startTime != 0 || endTime != 0) {
            _validateTimeRange(startTime, endTime);
        }
        round.startTime = startTime;
        round.endTime = endTime;
        emit RoundTimesUpdated(competitionId, cupId, seasonId, roundNumber, startTime, endTime);
    }

    function setRoundFixtures(
        bytes32 competitionId,
        bytes32 cupId,
        uint16 seasonId,
        uint32 roundNumber,
        bytes32[] calldata fixtureIds
    ) external onlyRole(ADMIN_ROLE) {
        RoundSchedule storage round = _requireRound(competitionId, cupId, seasonId, roundNumber);
        delete round.fixtureIds;
        uint256 n = fixtureIds.length;
        for (uint256 i; i < n; ++i) {
            round.fixtureIds.push(fixtureIds[i]);
        }
        emit RoundFixturesUpdated(competitionId, cupId, seasonId, roundNumber, n);
    }

    // --------------------------------------------
    //  Views — topology
    // --------------------------------------------

    /// @notice Domestic fee hubs for unsupported-market even-split (`FeeRouter`)
    function getAllDomesticPbrFeeHubs() external view returns (address[] memory hubs) {
        uint256 length = _leagueIds.length;
        hubs = new address[](length);
        for (uint256 i; i < length; ++i) {
            hubs[i] = _leagues[_leagueIds[i]].pbrFeeHub;
        }
    }

    function getLeagueIds() external view returns (bytes32[] memory) {
        return _leagueIds;
    }

    function getLeague(bytes32 leagueId) external view returns (address pbrFeeHub, bytes32[] memory cupIds) {
        League storage league = _requireLeague(leagueId);
        return (league.pbrFeeHub, league.cupIds);
    }

    function leagueExists(bytes32 leagueId) external view returns (bool) {
        return _leagues[leagueId].pbrFeeHub != address(0);
    }

    function getContinental() external view returns (bytes32[] memory cupIds) {
        if (!_continental.registered) revert ContinentalDoesNotExist();
        return _continental.cupIds;
    }

    function continentalExists() external view returns (bool) {
        return _continental.registered;
    }

    function getInternational() external view returns (bytes32[] memory cupIds) {
        if (!_international.registered) revert InternationalDoesNotExist();
        return _international.cupIds;
    }

    function internationalExists() external view returns (bool) {
        return _international.registered;
    }

    function getCupPbrTreasury(bytes32 cupId) external view returns (address) {
        return cupPbrTreasury[cupId];
    }

    // --------------------------------------------
    //  Views — calendar
    // --------------------------------------------

    function getSeasonMeta(bytes32 competitionId, bytes32 cupId, uint16 seasonId)
        external
        view
        returns (CupSeasonMeta memory)
    {
        return _seasonMeta[competitionId][cupId][seasonId];
    }

    function getFinalRound(bytes32 competitionId, bytes32 cupId, uint16 seasonId) external view returns (uint32) {
        return _seasonMeta[competitionId][cupId][seasonId].finalRound;
    }

    function getRound(bytes32 competitionId, bytes32 cupId, uint16 seasonId, uint32 roundNumber)
        external
        view
        returns (RoundSchedule memory)
    {
        return _requireRound(competitionId, cupId, seasonId, roundNumber);
    }

    function isRoundPublished(bytes32 competitionId, bytes32 cupId, uint16 seasonId, uint32 roundNumber)
        external
        view
        returns (bool)
    {
        return _isPublished(_rounds[competitionId][cupId][seasonId][roundNumber]);
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _addCup(bytes32 competitionId, bytes32[] storage cupIds, bytes32 cupId, address pbrTreasury) internal {
        if (cupId == bytes32(0)) revert ZeroId();
        if (pbrTreasury == address(0)) revert ZeroAddress();
        if (_findCupIndex(cupIds, cupId) != type(uint256).max) revert CupAlreadyExists(competitionId, cupId);
        if (cupPbrTreasury[cupId] != address(0)) revert CupTreasuryAlreadySet(cupId, cupPbrTreasury[cupId]);

        cupIds.push(cupId);
        cupPbrTreasury[cupId] = pbrTreasury;
        cupCompetitionId[cupId] = competitionId;

        emit CupAdded(competitionId, cupId, pbrTreasury, cupIds.length - 1);
    }

    function _requireLeague(bytes32 leagueId) internal view returns (League storage league) {
        league = _leagues[leagueId];
        if (league.pbrFeeHub == address(0)) revert LeagueDoesNotExist(leagueId);
    }

    function _requireCup(bytes32 competitionId, bytes32 cupId) internal view {
        if (cupCompetitionId[cupId] != competitionId) revert CupIdNotFound(competitionId, cupId);
    }

    function _requireSeason(bytes32 competitionId, bytes32 cupId, uint16 seasonId)
        internal
        view
        returns (CupSeasonMeta storage meta)
    {
        _requireCup(competitionId, cupId);
        meta = _seasonMeta[competitionId][cupId][seasonId];
        if (meta.finalRound == 0) revert SeasonNotOpen(competitionId, cupId, seasonId);
    }

    function _requireRound(bytes32 competitionId, bytes32 cupId, uint16 seasonId, uint32 roundNumber)
        internal
        view
        returns (RoundSchedule storage round)
    {
        _requireSeason(competitionId, cupId, seasonId);
        round = _rounds[competitionId][cupId][seasonId][roundNumber];
        if (round.roundNumber == 0) revert RoundDoesNotExist(competitionId, cupId, seasonId, roundNumber);
    }

    function _findCupIndex(bytes32[] storage cupIds, bytes32 cupId) internal view returns (uint256) {
        uint256 length = cupIds.length;
        for (uint256 i; i < length; ++i) {
            if (cupIds[i] == cupId) return i;
        }
        return type(uint256).max;
    }

    function _isPublished(RoundSchedule storage round) internal view returns (bool) {
        return round.roundNumber != 0 && round.startTime != 0 && round.endTime > round.startTime
            && round.fixtureIds.length > 0;
    }

    function _validateTimeRange(uint64 startTime, uint64 endTime) internal pure {
        if (endTime <= startTime) revert InvalidTimeRange(startTime, endTime);
    }
}
