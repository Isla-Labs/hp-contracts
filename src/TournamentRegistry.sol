// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import {
    Hub,
    Season,
    Tournament,
    TournamentType,
    RoundSchedule
} from "@base/global/types/TournamentTypes.sol";

/**
 * @title TournamentRegistry
 * @notice Canonical tournament topology + season calendars, keyed by `tournamentId`.
 * @dev Examples:
 *        - `EPL`: DOMESTIC, feeHubs = [{EPL, hub}], treasury = EPL pot
 *        - `FACUP`: DOMESTIC, feeHubs = [{EPL, hub}], treasury = FA Cup pot
 *        - `UCL`: CONTINENTAL, feeHubs = all domestic hubs, treasury = UCL pot
 *
 *      Domestic hubs are also registered globally so `FeeRouter` can even-split when a
 *      market has no league (`getAllDomesticPbrFeeHubs`).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TournamentRegistry is Initializable {
    address public admin;

    /// @notice Globally registered domestic hubs (`leagueId` → hub). Used by FeeRouter OOF split.
    mapping(bytes32 leagueId => address) public pbrFeeHubOf;
    bytes32[] private _leagueIds;

    mapping(bytes32 tournamentId => Tournament) private _tournaments;
    bytes32[] private _tournamentIds;

    event AdminSet(address indexed admin);
    event HubRegistered(bytes32 indexed leagueId, address indexed pbrFeeHub);
    event HubUpdated(bytes32 indexed leagueId, address indexed previous, address indexed pbrFeeHub);
    event TournamentCreated(
        bytes32 indexed tournamentId, TournamentType tournamentType, address indexed pbrTreasury
    );
    event HubAddedToTournament(bytes32 indexed tournamentId, bytes32 indexed leagueId, address pbrFeeHub);
    event HubRemovedFromTournament(bytes32 indexed tournamentId, bytes32 indexed leagueId);
    event PbrTreasuryUpdated(bytes32 indexed tournamentId, address indexed previous, address indexed pbrTreasury);
    event SeasonOpened(bytes32 indexed tournamentId, uint16 indexed seasonStartYear, uint32 finalRound);
    event RoundUpserted(bytes32 indexed tournamentId, uint16 indexed seasonStartYear, uint32 roundNumber);

    error ZeroAddress();
    error ZeroId();
    error NotAuthorized();
    error Exists();
    error NotFound();
    error HubAlreadyRegistered(bytes32 leagueId);
    error HubNotRegistered(bytes32 leagueId);
    error HubAlreadyLinked(bytes32 tournamentId, bytes32 leagueId);
    error HubNotLinked(bytes32 tournamentId, bytes32 leagueId);
    error HubMismatch(bytes32 leagueId, address expected, address actual);
    error SeasonExists(bytes32 tournamentId, uint16 seasonStartYear);
    error SeasonNotFound(bytes32 tournamentId, uint16 seasonStartYear);
    error InvalidFinalRound();
    error InvalidRoundNumber(uint32 roundNumber, uint32 finalRound);
    error InvalidTimeRange(uint64 startTime, uint64 endTime);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAuthorized();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_) external initializer {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
        emit AdminSet(admin_);
    }

    // --------------------------------------------
    //  Domestic hubs (FeeRouter)
    // --------------------------------------------

    /**
     * @notice Registers a domestic league hub (`leagueId` + `PbrFeeHub` address).
     * @dev Must exist before tournaments can link that hub.
     */
    function registerHub(Hub calldata hub) external onlyAdmin {
        if (hub.leagueId == bytes32(0)) revert ZeroId();
        if (hub.pbrFeeHub == address(0)) revert ZeroAddress();
        if (pbrFeeHubOf[hub.leagueId] != address(0)) revert HubAlreadyRegistered(hub.leagueId);

        pbrFeeHubOf[hub.leagueId] = hub.pbrFeeHub;
        _leagueIds.push(hub.leagueId);
        emit HubRegistered(hub.leagueId, hub.pbrFeeHub);
    }

    function setHub(bytes32 leagueId, address pbrFeeHub) external onlyAdmin {
        if (pbrFeeHubOf[leagueId] == address(0)) revert HubNotRegistered(leagueId);
        if (pbrFeeHub == address(0)) revert ZeroAddress();

        address previous = pbrFeeHubOf[leagueId];
        pbrFeeHubOf[leagueId] = pbrFeeHub;
        emit HubUpdated(leagueId, previous, pbrFeeHub);
    }

    // --------------------------------------------
    //  Tournament registration
    // --------------------------------------------

    /**
     * @notice Creates a tournament with linked fee hubs and treasury.
     * @param tournamentId Stable id (e.g. keccak256("EPL"), keccak256("UCL")).
     * @param tournamentType Domestic / continental / international.
     * @param feeHubs Domestic hubs that should route fees to `pbrTreasury` (must be registered).
     * @param pbrTreasury Cup-specific `PbrTreasury` (may be zero until deployed).
     */
    function createTournament(
        bytes32 tournamentId,
        TournamentType tournamentType,
        Hub[] calldata feeHubs,
        address pbrTreasury
    ) external onlyAdmin {
        if (tournamentId == bytes32(0)) revert ZeroId();
        if (_tournaments[tournamentId].tournamentId != bytes32(0)) revert Exists();

        Tournament storage t = _tournaments[tournamentId];
        t.tournamentType = tournamentType;
        t.tournamentId = tournamentId;
        t.pbrTreasury = pbrTreasury;

        uint256 length = feeHubs.length;
        for (uint256 i; i < length; ++i) {
            _linkHub(t, tournamentId, feeHubs[i]);
        }

        _tournamentIds.push(tournamentId);
        emit TournamentCreated(tournamentId, tournamentType, pbrTreasury);
    }

    function addHub(bytes32 tournamentId, Hub calldata hub) external onlyAdmin {
        Tournament storage t = _requireTournament(tournamentId);
        _linkHub(t, tournamentId, hub);
    }

    function removeHub(bytes32 tournamentId, bytes32 leagueId) external onlyAdmin {
        Tournament storage t = _requireTournament(tournamentId);

        uint256 length = t.feeHubs.length;
        uint256 index = type(uint256).max;
        for (uint256 i; i < length; ++i) {
            if (t.feeHubs[i].leagueId == leagueId) {
                index = i;
                break;
            }
        }
        if (index == type(uint256).max) revert HubNotLinked(tournamentId, leagueId);

        uint256 last = length - 1;
        if (index != last) t.feeHubs[index] = t.feeHubs[last];
        t.feeHubs.pop();
        emit HubRemovedFromTournament(tournamentId, leagueId);
    }

    function setPbrTreasury(bytes32 tournamentId, address pbrTreasury) external onlyAdmin {
        Tournament storage t = _requireTournament(tournamentId);
        address previous = t.pbrTreasury;
        t.pbrTreasury = pbrTreasury;
        emit PbrTreasuryUpdated(tournamentId, previous, pbrTreasury);
    }

    // --------------------------------------------
    //  Season calendar
    // --------------------------------------------

    function openSeason(bytes32 tournamentId, uint16 seasonStartYear, uint32 finalRound) external onlyAdmin {
        if (seasonStartYear == 0) revert ZeroId();
        if (finalRound == 0) revert InvalidFinalRound();

        Tournament storage t = _requireTournament(tournamentId);
        if (_seasonIndex(t, seasonStartYear) != type(uint256).max) {
            revert SeasonExists(tournamentId, seasonStartYear);
        }

        t.seasons.push(
            Season({
                seasonStartYear: seasonStartYear, finalRound: finalRound, roundCount: 0, rounds: new RoundSchedule[](0)
            })
        );
        emit SeasonOpened(tournamentId, seasonStartYear, finalRound);
    }

    function upsertRound(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule calldata round)
        external
        onlyAdmin
    {
        Tournament storage t = _requireTournament(tournamentId);
        uint256 sIndex = _seasonIndex(t, seasonStartYear);
        if (sIndex == type(uint256).max) revert SeasonNotFound(tournamentId, seasonStartYear);

        Season storage season = t.seasons[sIndex];
        if (round.roundNumber == 0 || round.roundNumber > season.finalRound) {
            revert InvalidRoundNumber(round.roundNumber, season.finalRound);
        }
        if (round.endTime <= round.startTime) revert InvalidTimeRange(round.startTime, round.endTime);

        uint256 rIndex = _roundIndex(season, round.roundNumber);
        if (rIndex == type(uint256).max) {
            season.rounds.push(round);
            unchecked {
                ++season.roundCount;
            }
        } else {
            RoundSchedule storage stored = season.rounds[rIndex];
            stored.startTime = round.startTime;
            stored.endTime = round.endTime;
            delete stored.fixtureIds;
            uint256 n = round.fixtureIds.length;
            for (uint256 i; i < n; ++i) {
                stored.fixtureIds.push(round.fixtureIds[i]);
            }
        }

        emit RoundUpserted(tournamentId, seasonStartYear, round.roundNumber);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @notice Domestic fee hubs for unsupported-market even-split (`FeeRouter`)
    function getAllDomesticPbrFeeHubs() external view returns (address[] memory hubs) {
        uint256 length = _leagueIds.length;
        hubs = new address[](length);
        for (uint256 i; i < length; ++i) {
            hubs[i] = pbrFeeHubOf[_leagueIds[i]];
        }
    }

    function getAllHubs() external view returns (Hub[] memory hubs) {
        uint256 length = _leagueIds.length;
        hubs = new Hub[](length);
        for (uint256 i; i < length; ++i) {
            bytes32 leagueId = _leagueIds[i];
            hubs[i] = Hub({ leagueId: leagueId, pbrFeeHub: pbrFeeHubOf[leagueId] });
        }
    }

    function getLeagueIds() external view returns (bytes32[] memory) {
        return _leagueIds;
    }

    function getTournament(bytes32 tournamentId) external view returns (Tournament memory) {
        _requireTournament(tournamentId);
        return _tournaments[tournamentId];
    }

    function getFeeHubs(bytes32 tournamentId) external view returns (Hub[] memory) {
        _requireTournament(tournamentId);
        return _tournaments[tournamentId].feeHubs;
    }

    function getPbrTreasury(bytes32 tournamentId) external view returns (address) {
        _requireTournament(tournamentId);
        return _tournaments[tournamentId].pbrTreasury;
    }

    function tournamentExists(bytes32 tournamentId) external view returns (bool) {
        return _tournaments[tournamentId].tournamentId != bytes32(0);
    }

    function allTournamentIds() external view returns (bytes32[] memory) {
        return _tournamentIds;
    }

    function tournamentCount() external view returns (uint256) {
        return _tournamentIds.length;
    }

    /// @notice Tournaments that list a hub for `leagueId`
    function getTournamentsForLeague(bytes32 leagueId) external view returns (bytes32[] memory ids) {
        uint256 length = _tournamentIds.length;
        bytes32[] memory tmp = new bytes32[](length);
        uint256 count;

        for (uint256 i; i < length; ++i) {
            bytes32 tournamentId = _tournamentIds[i];
            Hub[] storage feeHubs = _tournaments[tournamentId].feeHubs;
            uint256 n = feeHubs.length;
            for (uint256 j; j < n; ++j) {
                if (feeHubs[j].leagueId == leagueId) {
                    tmp[count] = tournamentId;
                    unchecked {
                        ++count;
                    }
                    break;
                }
            }
        }

        ids = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = tmp[i];
        }
    }

    function getSeason(bytes32 tournamentId, uint16 seasonStartYear) external view returns (Season memory) {
        Tournament storage t = _requireTournament(tournamentId);
        uint256 sIndex = _seasonIndex(t, seasonStartYear);
        if (sIndex == type(uint256).max) revert SeasonNotFound(tournamentId, seasonStartYear);
        return t.seasons[sIndex];
    }

    function isRoundPublished(bytes32 tournamentId, uint16 seasonStartYear, uint32 roundNumber)
        external
        view
        returns (bool)
    {
        Tournament storage t = _tournaments[tournamentId];
        if (t.tournamentId == bytes32(0)) return false;

        uint256 sIndex = _seasonIndex(t, seasonStartYear);
        if (sIndex == type(uint256).max) return false;

        Season storage season = t.seasons[sIndex];
        uint256 rIndex = _roundIndex(season, roundNumber);
        if (rIndex == type(uint256).max) return false;

        RoundSchedule storage round = season.rounds[rIndex];
        return round.startTime != 0 && round.endTime > round.startTime && round.fixtureIds.length > 0;
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _linkHub(Tournament storage t, bytes32 tournamentId, Hub calldata hub) internal {
        if (hub.leagueId == bytes32(0)) revert ZeroId();
        if (hub.pbrFeeHub == address(0)) revert ZeroAddress();

        address registered = pbrFeeHubOf[hub.leagueId];
        if (registered == address(0)) revert HubNotRegistered(hub.leagueId);
        if (registered != hub.pbrFeeHub) revert HubMismatch(hub.leagueId, registered, hub.pbrFeeHub);

        uint256 length = t.feeHubs.length;
        for (uint256 i; i < length; ++i) {
            if (t.feeHubs[i].leagueId == hub.leagueId) revert HubAlreadyLinked(tournamentId, hub.leagueId);
        }

        t.feeHubs.push(hub);
        emit HubAddedToTournament(tournamentId, hub.leagueId, hub.pbrFeeHub);
    }

    function _requireTournament(bytes32 tournamentId) internal view returns (Tournament storage t) {
        t = _tournaments[tournamentId];
        if (t.tournamentId == bytes32(0)) revert NotFound();
    }

    function _seasonIndex(Tournament storage t, uint16 seasonStartYear) internal view returns (uint256) {
        uint256 length = t.seasons.length;
        for (uint256 i; i < length; ++i) {
            if (t.seasons[i].seasonStartYear == seasonStartYear) return i;
        }
        return type(uint256).max;
    }

    function _roundIndex(Season storage season, uint32 roundNumber) internal view returns (uint256) {
        uint256 length = season.rounds.length;
        for (uint256 i; i < length; ++i) {
            if (season.rounds[i].roundNumber == roundNumber) return i;
        }
        return type(uint256).max;
    }
}
