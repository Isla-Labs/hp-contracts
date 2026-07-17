// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { RegistryErrors as Errors } from "@base/global/libraries/errors/RegistryErrors.sol";
import { RegistryEvents as Events } from "@base/global/libraries/events/RegistryEvents.sol";
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
 *        - `EPL`: DOMESTIC_LEAGUE, feeHubs = [{EPL, hub}], treasury = EPL pot
 *        - `FACUP`: DOMESTIC_CUP, feeHubs = [{EPL, hub}], treasury = FA Cup pot
 *        - `UCL`: CONTINENTAL, feeHubs = all domestic hubs, treasury = UCL pot
 *
 *      Access:
 *      - `DEPLOYER_ROLE` (TournamentTimelock): hubs, tournaments, seasons / rounds.
 *      - `ADMIN_ROLE` (multisig initially): hub / treasury address updates.
 *
 *      Domestic league hubs are also registered globally so `FeeRouter` can even-split when a
 *      market has no league (`getAllDomesticPbrFeeHubs`).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TournamentRegistry is Initializable, AccessControl {
    /// @notice TournamentTimelock — hub / tournament / calendar deployment
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    /// @notice Admin (multisig) — sensitive destination updates
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    /// @notice Globally registered domestic hubs (`leagueId` → hub). Used by FeeRouter OOF split.
    mapping(bytes32 leagueId => address) public pbrFeeHubOf;
    bytes32[] private _leagueIds;

    mapping(bytes32 tournamentId => Tournament) private _tournaments;
    bytes32[] private _tournamentIds;

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param admin_ Multisig granted `ADMIN_ROLE` (+ `DEFAULT_ADMIN_ROLE` for role management).
     * @param deployer_ TournamentTimelock granted `DEPLOYER_ROLE`.
     */
    function initialize(address admin_, address deployer_) external initializer {
        if (admin_ == address(0) || deployer_ == address(0)) revert Errors.ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(DEPLOYER_ROLE, deployer_);
    }

    // --------------------------------------------
    //  Domestic hubs (FeeRouter)
    // --------------------------------------------

    /**
     * @notice Registers a domestic league hub (`leagueId` + `PbrFeeHub` address).
     * @dev Must exist before tournaments can link that hub.
     */
    function registerHub(Hub calldata hub) external onlyRole(DEPLOYER_ROLE) {
        if (hub.leagueId == bytes32(0)) revert Errors.ZeroId();
        if (hub.pbrFeeHub == address(0)) revert Errors.ZeroAddress();
        if (pbrFeeHubOf[hub.leagueId] != address(0)) revert Errors.HubAlreadyRegistered(hub.leagueId);

        pbrFeeHubOf[hub.leagueId] = hub.pbrFeeHub;
        _leagueIds.push(hub.leagueId);
        emit Events.HubRegistered(hub.leagueId, hub.pbrFeeHub);
    }

    function setHub(bytes32 leagueId, address pbrFeeHub) external onlyRole(ADMIN_ROLE) {
        if (pbrFeeHubOf[leagueId] == address(0)) revert Errors.HubNotRegistered(leagueId);
        if (pbrFeeHub == address(0)) revert Errors.ZeroAddress();

        address previous = pbrFeeHubOf[leagueId];
        pbrFeeHubOf[leagueId] = pbrFeeHub;
        emit Events.HubUpdated(leagueId, previous, pbrFeeHub);
    }

    // --------------------------------------------
    //  Tournament registration
    // --------------------------------------------

    /**
     * @notice Creates a tournament with linked fee hubs and treasury.
     * @param tournamentId Stable id (e.g. keccak256("EPL"), keccak256("UCL")).
     * @param tournamentType Domestic league / domestic cup / continental / international.
     * @param feeHubs Domestic hubs that should route fees to `pbrTreasury` (must be registered).
     * @param pbrTreasury Tournament-specific `PbrTreasury` (may be zero until deployed).
     */
    function createTournament(
        bytes32 tournamentId,
        TournamentType tournamentType,
        Hub[] calldata feeHubs,
        address pbrTreasury
    ) external onlyRole(DEPLOYER_ROLE) {
        if (tournamentId == bytes32(0)) revert Errors.ZeroId();
        if (_tournaments[tournamentId].tournamentId != bytes32(0)) revert Errors.Exists();

        Tournament storage t = _tournaments[tournamentId];
        t.tournamentType = tournamentType;
        t.tournamentId = tournamentId;
        t.pbrTreasury = pbrTreasury;

        uint256 length = feeHubs.length;
        for (uint256 i; i < length; ++i) {
            _linkHub(t, tournamentId, feeHubs[i]);
        }

        _tournamentIds.push(tournamentId);
        emit Events.TournamentCreated(tournamentId, tournamentType, pbrTreasury);
    }

    function addHub(bytes32 tournamentId, Hub calldata hub) external onlyRole(DEPLOYER_ROLE) {
        Tournament storage t = _requireTournament(tournamentId);
        _linkHub(t, tournamentId, hub);
    }

    function removeHub(bytes32 tournamentId, bytes32 leagueId) external onlyRole(DEPLOYER_ROLE) {
        Tournament storage t = _requireTournament(tournamentId);

        uint256 length = t.feeHubs.length;
        uint256 index = type(uint256).max;
        for (uint256 i; i < length; ++i) {
            if (t.feeHubs[i].leagueId == leagueId) {
                index = i;
                break;
            }
        }
        if (index == type(uint256).max) revert Errors.HubNotLinked(tournamentId, leagueId);

        uint256 last = length - 1;
        if (index != last) t.feeHubs[index] = t.feeHubs[last];
        t.feeHubs.pop();
        emit Events.HubRemovedFromTournament(tournamentId, leagueId);
    }

    function setPbrTreasury(bytes32 tournamentId, address pbrTreasury) external onlyRole(ADMIN_ROLE) {
        Tournament storage t = _requireTournament(tournamentId);
        address previous = t.pbrTreasury;
        t.pbrTreasury = pbrTreasury;
        emit Events.PbrTreasuryUpdated(tournamentId, previous, pbrTreasury);
    }

    // --------------------------------------------
    //  Season calendar
    // --------------------------------------------

    function openSeason(bytes32 tournamentId, uint16 seasonStartYear, uint32 finalRound)
        external
        onlyRole(DEPLOYER_ROLE)
    {
        if (seasonStartYear == 0) revert Errors.ZeroId();
        if (finalRound == 0) revert Errors.InvalidFinalRound();

        Tournament storage t = _requireTournament(tournamentId);
        if (_seasonIndex(t, seasonStartYear) != type(uint256).max) {
            revert Errors.SeasonExists(tournamentId, seasonStartYear);
        }

        t.seasons.push(
            Season({
                seasonStartYear: seasonStartYear, finalRound: finalRound, roundCount: 0, rounds: new RoundSchedule[](0)
            })
        );
        emit Events.SeasonOpened(tournamentId, seasonStartYear, finalRound);
    }

    function upsertRound(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule calldata round)
        external
        onlyRole(DEPLOYER_ROLE)
    {
        Tournament storage t = _requireTournament(tournamentId);
        uint256 sIndex = _seasonIndex(t, seasonStartYear);
        if (sIndex == type(uint256).max) revert Errors.SeasonNotFound(tournamentId, seasonStartYear);

        Season storage season = t.seasons[sIndex];
        if (round.roundNumber == 0 || round.roundNumber > season.finalRound) {
            revert Errors.InvalidRoundNumber(round.roundNumber, season.finalRound);
        }
        if (round.endTime <= round.startTime) revert Errors.InvalidTimeRange(round.startTime, round.endTime);

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

        emit Events.RoundUpserted(tournamentId, seasonStartYear, round.roundNumber);
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

    function getPbrTreasury(bytes32 tournamentId) external view returns (address) {
        return _requireTournament(tournamentId).pbrTreasury;
    }

    function getFinalRound(bytes32 tournamentId, uint16 seasonStartYear) external view returns (uint32) {
        return _requireSeason(tournamentId, seasonStartYear).finalRound;
    }

    function getRound(bytes32 tournamentId, uint16 seasonStartYear, uint32 roundNumber)
        external
        view
        returns (RoundSchedule memory)
    {
        Season storage season = _requireSeason(tournamentId, seasonStartYear);
        uint256 rIndex = _roundIndex(season, roundNumber);
        if (rIndex == type(uint256).max) revert Errors.RoundNotFound(tournamentId, seasonStartYear, roundNumber);
        return season.rounds[rIndex];
    }

    /// @notice True when the round exists with a valid time range and at least one fixture.
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
        if (hub.leagueId == bytes32(0)) revert Errors.ZeroId();
        if (hub.pbrFeeHub == address(0)) revert Errors.ZeroAddress();

        address registered = pbrFeeHubOf[hub.leagueId];
        if (registered == address(0)) revert Errors.HubNotRegistered(hub.leagueId);
        if (registered != hub.pbrFeeHub) revert Errors.HubMismatch(hub.leagueId, registered, hub.pbrFeeHub);

        uint256 length = t.feeHubs.length;
        for (uint256 i; i < length; ++i) {
            if (t.feeHubs[i].leagueId == hub.leagueId) revert Errors.HubAlreadyLinked(tournamentId, hub.leagueId);
        }

        t.feeHubs.push(hub);
        emit Events.HubAddedToTournament(tournamentId, hub.leagueId, hub.pbrFeeHub);
    }

    function _requireTournament(bytes32 tournamentId) internal view returns (Tournament storage t) {
        t = _tournaments[tournamentId];
        if (t.tournamentId == bytes32(0)) revert Errors.NotFound();
    }

    function _requireSeason(bytes32 tournamentId, uint16 seasonStartYear) internal view returns (Season storage) {
        Tournament storage t = _requireTournament(tournamentId);
        uint256 sIndex = _seasonIndex(t, seasonStartYear);
        if (sIndex == type(uint256).max) revert Errors.SeasonNotFound(tournamentId, seasonStartYear);
        return t.seasons[sIndex];
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
