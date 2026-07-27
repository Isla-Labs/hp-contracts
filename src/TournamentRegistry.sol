// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { AccessRoles as Roles } from "@roles/AccessRoles.sol";
import { RegistryErrors as Errors } from "@errors/RegistryErrors.sol";
import { RegistryEvents as Events } from "@events/RegistryEvents.sol";
import { Hub, Season, Tournament, TournamentType, RoundSchedule } from "@types/TournamentTypes.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";

/**
 * @title TournamentRegistry
 * @notice Canonical tournament topology, season calendars, and vault membership SoT.
 * @dev Examples:
 *        - `EPL`: DOMESTIC_LEAGUE, feeHubs = [{EPL, hub}], treasury = EPL pot
 *        - `FACUP`: DOMESTIC_CUP, feeHubs = [{EPL, hub}], treasury = FA Cup pot
 *        - `UCL`: CONTINENTAL, feeHubs = all domestic hubs, treasury = UCL pot
 *
 *      Access:
 *      - `CATEGORY_ONE` (`ConstitutionalTimelock` / `DeployTournament`): `registerHub`,
 *        tournament create, `linkHub`, vault membership.
 *      - `CATEGORY_TWO` / `CATEGORY_THREE`: vault membership + season calendar (cat-3).
 *
 *      Vault membership is the SoT here; each write syncs a local cache on the tournament's
 *      `PbrTreasury` so crank paths never re-read this registry for the vault set.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TournamentRegistry is Initializable, AddressBook, AccessControl, ITournamentRegistry {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    IPlayerSetRegistry public playerSetRegistry;

    /// @notice Globally registered domestic hubs (`leagueId` → hub). Used by FeeRouter OOF split.
    mapping(bytes32 leagueId => address) public pbrFeeHubOf;
    bytes32[] private _leagueIds;

    mapping(bytes32 tournamentId => Tournament) private _tournaments;
    bytes32[] private _tournamentIds;

    /// @dev SoT vault set per tournament (mirrored to `PbrTreasury` cache on write).
    mapping(bytes32 tournamentId => address[]) private _registeredVaults;
    mapping(bytes32 tournamentId => mapping(address vault => uint256)) private _registeredVaultIndex; // 1-based
    mapping(bytes32 tournamentId => mapping(address vault => bool)) private _isVaultRegistered;

    // --------------------------------------------
    //  Access
    // --------------------------------------------

    modifier onlyMembershipAdmin() {
        address sender = _msgSender();
        if (
            !hasRole(Roles.CATEGORY_ONE, sender) && !hasRole(Roles.CATEGORY_TWO, sender)
                && !hasRole(Roles.CATEGORY_THREE, sender)
        ) {
            revert Errors.NotAuthorized();
        }
        _;
    }

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) {
        _disableInitializers();
    }

    /// @notice Resolves DAO / cat-1 / Automator / `PlayerSetRegistry` from `AddressProvider` once.
    function initialize() external initializer {
        address constitutionalTimelock_ = _getAddress(_addressKey(Addresses.CONSTITUTIONAL_TIMELOCK));
        address automator_ = _getAddress(_addressKey(Addresses.AUTOMATOR));
        address dao_ = _getAddress(_addressKey(Addresses.DAO));
        address playerSetRegistry_ = _getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY));

        playerSetRegistry = IPlayerSetRegistry(playerSetRegistry_);
        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_ONE, constitutionalTimelock_);
        _grantRole(Roles.CATEGORY_THREE, automator_);
    }

    // --------------------------------------------
    //  Domestic hubs (FeeRouter) — CATEGORY_ONE
    // --------------------------------------------

    /**
     * @notice Registers a domestic league hub (`leagueId` + `PbrFeeHub` address).
     * @dev Used only when deploying a new DOMESTIC_LEAGUE (other types use existing league hubs):
     *      STEP1: call registerHub
     *      STEP2: call createTournament
     */
    function registerHub(Hub calldata hub) external onlyRole(Roles.CATEGORY_ONE) {
        if (hub.leagueId == bytes32(0)) revert Errors.ZeroId();
        if (hub.pbrFeeHub == address(0)) revert Errors.ZeroAddress();
        if (pbrFeeHubOf[hub.leagueId] != address(0)) revert Errors.HubAlreadyRegistered(hub.leagueId);

        pbrFeeHubOf[hub.leagueId] = hub.pbrFeeHub;
        _leagueIds.push(hub.leagueId);
        emit Events.HubRegistered(hub.leagueId, hub.pbrFeeHub);
    }

    // --------------------------------------------
    //  Tournament registration — CATEGORY_ONE
    // --------------------------------------------

    /**
     * @notice Creates a tournament with linked fee hubs and treasury.
     * @param tournamentId Stable id (e.g. keccak256("EPL"), keccak256("UCL")).
     *      For `DOMESTIC_LEAGUE`, must equal the `leagueId` previously passed to `registerHub`.
     * @param tournamentType Domestic league / domestic cup / continental / international.
     * @param feeHubs Domestic hubs that should route fees to `pbrTreasury` (must be registered).
     * @param pbrTreasury Tournament-specific `PbrTreasury` (required; deploy alongside the tournament).
     */
    function createTournament(
        bytes32 tournamentId,
        TournamentType tournamentType,
        Hub[] calldata feeHubs,
        address pbrTreasury
    ) external onlyRole(Roles.CATEGORY_ONE) {
        if (tournamentId == bytes32(0)) revert Errors.ZeroId();
        if (pbrTreasury == address(0)) revert Errors.ZeroAddress();
        if (_tournaments[tournamentId].tournamentId != bytes32(0)) revert Errors.Exists();
        if (tournamentType == TournamentType.DOMESTIC_LEAGUE && pbrFeeHubOf[tournamentId] == address(0)) {
            revert Errors.HubNotRegistered(tournamentId);
        }

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
        if (tournamentType == TournamentType.DOMESTIC_LEAGUE) {
            emit Events.DomesticLeagueCreated(tournamentId, pbrTreasury);
        }
    }

    /**
     * @notice Links an additional registered domestic hub to a CONTINENTAL / INTERNATIONAL tournament.
     * @dev Used when a new domestic league comes online and existing multi-hub tournaments must
     *      include its hub. Domestic leagues/cups get their hub only at `createTournament`.
     */
    function linkHub(bytes32 tournamentId, Hub calldata hub) external onlyRole(Roles.CATEGORY_ONE) {
        Tournament storage t = _requireTournament(tournamentId);
        TournamentType tournamentType = t.tournamentType;
        if (tournamentType != TournamentType.CONTINENTAL && tournamentType != TournamentType.INTERNATIONAL) {
            revert Errors.InvalidLinkTarget(tournamentType);
        }
        _linkHub(t, tournamentId, hub);
    }

    // --------------------------------------------
    //  Vault membership SoT — CATEGORY_ONE / TWO / THREE
    // --------------------------------------------

    /// @inheritdoc ITournamentRegistry
    function registerVaults(bytes32 tournamentId, address[] calldata vaults) external onlyMembershipAdmin {
        Tournament storage t = _requireTournament(tournamentId);
        address treasury = t.pbrTreasury;
        uint256 length = vaults.length;
        for (uint256 i; i < length; ++i) {
            _registerVault(tournamentId, treasury, vaults[i]);
        }
    }

    /// @inheritdoc ITournamentRegistry
    function unregisterVaults(bytes32 tournamentId, address[] calldata vaults) external onlyMembershipAdmin {
        Tournament storage t = _requireTournament(tournamentId);
        address treasury = t.pbrTreasury;
        uint256 length = vaults.length;
        for (uint256 i; i < length; ++i) {
            _unregisterVault(tournamentId, treasury, vaults[i]);
        }
    }

    // --------------------------------------------
    //  Season calendar — CATEGORY_THREE
    // --------------------------------------------

    /**
     * @notice Opens a season calendar for `tournamentId`.
     * @param tournamentId Tournament HPID.
     * @param seasonId Season HPID.
     * @param seasonStartYear Local season key (e.g. 2025 for 2025/26).
     * @param finalRound Highest round number for the season.
     */
    function openSeason(
        bytes32 tournamentId,
        bytes32 seasonId,
        uint16 seasonStartYear,
        uint32 finalRound
    ) external onlyRole(Roles.CATEGORY_THREE) {
        if (seasonId == bytes32(0) || seasonStartYear == 0) revert Errors.ZeroId();
        if (finalRound == 0) revert Errors.InvalidFinalRound();

        Tournament storage t = _requireTournament(tournamentId);
        if (_seasonIndex(t, seasonStartYear) != type(uint256).max) {
            revert Errors.SeasonExists(tournamentId, seasonStartYear);
        }

        t.seasons
            .push(
                Season({
                    seasonId: seasonId,
                    seasonStartYear: seasonStartYear,
                    finalRound: finalRound,
                    roundCount: 0,
                    rounds: new RoundSchedule[](0)
                })
            );
        emit Events.SeasonOpened(tournamentId, seasonId, seasonStartYear, finalRound);
    }

    function upsertRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        RoundSchedule calldata round
    ) external onlyRole(Roles.CATEGORY_THREE) {
        _upsertRound(tournamentId, seasonStartYear, round);
    }

    /// @notice Bulk `upsertRound` for calendar bootstrap / matchweek ingest.
    function upsertRounds(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        RoundSchedule[] calldata rounds
    ) external onlyRole(Roles.CATEGORY_THREE) {
        uint256 length = rounds.length;
        for (uint256 i; i < length; ++i) {
            _upsertRound(tournamentId, seasonStartYear, rounds[i]);
        }
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function tournamentCount() external view returns (uint256) {
        return _tournamentIds.length;
    }

    /// @notice Domestic fee hubs for unsupported-market even-split (`FeeRouter`)
    function getAllDomesticPbrFeeHubs() external view returns (address[] memory hubs) {
        uint256 length = _leagueIds.length;
        hubs = new address[](length);
        for (uint256 i; i < length; ++i) {
            hubs[i] = pbrFeeHubOf[_leagueIds[i]];
        }
    }

    /// @notice All registered domestic hubs (league id + hub address).
    function getAllDomesticHubs() external view returns (Hub[] memory hubs) {
        uint256 length = _leagueIds.length;
        hubs = new Hub[](length);
        for (uint256 i; i < length; ++i) {
            bytes32 leagueId = _leagueIds[i];
            hubs[i] = Hub({ leagueId: leagueId, pbrFeeHub: pbrFeeHubOf[leagueId] });
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

    /// @inheritdoc ITournamentRegistry
    function isVaultRegistered(bytes32 tournamentId, address vault) external view returns (bool) {
        return _isVaultRegistered[tournamentId][vault];
    }

    /// @inheritdoc ITournamentRegistry
    function getRegisteredVaults(bytes32 tournamentId) external view returns (address[] memory) {
        _requireTournament(tournamentId);
        return _registeredVaults[tournamentId];
    }

    function getFinalRound(bytes32 tournamentId, uint16 seasonStartYear) external view returns (uint32) {
        return _requireSeason(tournamentId, seasonStartYear).finalRound;
    }

    /// @notice StatsPerform tournament calendar UUID (`tmcl`) for a season.
    function getSeasonId(bytes32 tournamentId, uint16 seasonStartYear) external view returns (bytes32) {
        return _requireSeason(tournamentId, seasonStartYear).seasonId;
    }

    function getSeason(bytes32 tournamentId, uint16 seasonStartYear) external view returns (Season memory) {
        return _requireSeason(tournamentId, seasonStartYear);
    }

    /**
     * @notice Seasons under one tournament, oldest `seasonStartYear` first.
     * @dev CRE `eligibility-store` uses this on `DomesticLeagueCreated` / `SeasonOpened` to
     *      `SYNC_LEAGUE` into EligibilityStore's RunBook.
     */
    function getSeasonsOldestFirst(bytes32 tournamentId)
        external
        view
        returns (bytes32[] memory seasonIds, uint16[] memory seasonStartYears)
    {
        Tournament storage t = _requireTournament(tournamentId);
        uint256 sLen = t.seasons.length;
        seasonIds = new bytes32[](sLen);
        seasonStartYears = new uint16[](sLen);
        uint256 count;
        for (uint256 j; j < sLen; ++j) {
            bytes32 seasonId = t.seasons[j].seasonId;
            if (seasonId == bytes32(0)) continue;
            seasonIds[count] = seasonId;
            seasonStartYears[count] = t.seasons[j].seasonStartYear;
            unchecked {
                ++count;
            }
        }
        if (count != sLen) {
            bytes32[] memory trimmed = new bytes32[](count);
            uint16[] memory trimmedYears = new uint16[](count);
            for (uint256 i; i < count; ++i) {
                trimmed[i] = seasonIds[i];
                trimmedYears[i] = seasonStartYears[i];
            }
            seasonIds = trimmed;
            seasonStartYears = trimmedYears;
        }
        _sortSeasonsOldestFirst(seasonIds, seasonStartYears, count);
    }

    /**
     * @notice All non-zero season calendar ids with start years, oldest `seasonStartYear` first.
     * @dev CRE squad-fill walks this list in order (historical catch-up before newer calendars).
     *      Oldest-first also supports later-season status checks (e.g. newTransfer / backFromLoan)
     *      against already-filled prior seasons. `seasonStartYears[i]` aligns with `seasonIds[i]`.
     */
    function getSeasonIdsOldestFirst()
        external
        view
        returns (bytes32[] memory seasonIds, uint16[] memory seasonStartYears)
    {
        uint256 total;
        uint256 tLen = _tournamentIds.length;
        for (uint256 i; i < tLen; ++i) {
            total += _tournaments[_tournamentIds[i]].seasons.length;
        }

        seasonIds = new bytes32[](total);
        seasonStartYears = new uint16[](total);
        uint256 count;

        for (uint256 i; i < tLen; ++i) {
            Season[] storage seasons = _tournaments[_tournamentIds[i]].seasons;
            uint256 sLen = seasons.length;
            for (uint256 j; j < sLen; ++j) {
                bytes32 seasonId = seasons[j].seasonId;
                if (seasonId == bytes32(0)) continue;
                seasonIds[count] = seasonId;
                seasonStartYears[count] = seasons[j].seasonStartYear;
                unchecked {
                    ++count;
                }
            }
        }

        // Shrink if any zero seasonIds were skipped.
        if (count != total) {
            bytes32[] memory trimmed = new bytes32[](count);
            uint16[] memory trimmedYears = new uint16[](count);
            for (uint256 i; i < count; ++i) {
                trimmed[i] = seasonIds[i];
                trimmedYears[i] = seasonStartYears[i];
            }
            seasonIds = trimmed;
            seasonStartYears = trimmedYears;
        }

        _sortSeasonsOldestFirst(seasonIds, seasonStartYears, count);
    }

    function getRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (RoundSchedule memory) {
        Season storage season = _requireSeason(tournamentId, seasonStartYear);
        uint256 rIndex = _roundIndex(season, roundNumber);
        if (rIndex == type(uint256).max) revert Errors.RoundNotFound(tournamentId, seasonStartYear, roundNumber);
        return season.rounds[rIndex];
    }

    /// @notice True when the round exists with a valid time range and at least one fixture.
    function isRoundPublished(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (bool) {
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

    function _upsertRound(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule calldata round) internal {
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

    function _registerVault(bytes32 tournamentId, address treasury, address vault) private {
        if (vault == address(0)) revert Errors.ZeroAddress();
        if (vault.code.length == 0) revert Errors.UnknownVault(vault);
        if (playerSetRegistry.playerIdOfVault(vault) == bytes32(0)) revert Errors.UnknownVault(vault);
        if (_isVaultRegistered[tournamentId][vault]) revert Errors.VaultAlreadyRegistered(tournamentId, vault);

        _registeredVaults[tournamentId].push(vault);
        _registeredVaultIndex[tournamentId][vault] = _registeredVaults[tournamentId].length;
        _isVaultRegistered[tournamentId][vault] = true;
        emit Events.VaultRegistered(tournamentId, vault);

        IPbrTreasury(treasury).syncRegisterVault(vault);
    }

    function _unregisterVault(bytes32 tournamentId, address treasury, address vault) private {
        if (!_isVaultRegistered[tournamentId][vault]) revert Errors.VaultNotRegistered(tournamentId, vault);

        uint256 index0 = _registeredVaultIndex[tournamentId][vault] - 1;
        address[] storage vaults = _registeredVaults[tournamentId];
        uint256 last = vaults.length - 1;
        if (index0 != last) {
            address moved = vaults[last];
            vaults[index0] = moved;
            _registeredVaultIndex[tournamentId][moved] = index0 + 1;
        }
        vaults.pop();
        delete _registeredVaultIndex[tournamentId][vault];
        delete _isVaultRegistered[tournamentId][vault];
        emit Events.VaultUnregistered(tournamentId, vault);

        IPbrTreasury(treasury).syncUnregisterVault(vault);
    }

    /// @dev In-place insertion sort by `seasonStartYear` ascending (stable for equal years).
    function _sortSeasonsOldestFirst(
        bytes32[] memory seasonIds,
        uint16[] memory seasonStartYears,
        uint256 count
    ) private pure {
        for (uint256 i = 1; i < count; ++i) {
            bytes32 id = seasonIds[i];
            uint16 startYear = seasonStartYears[i];
            uint256 j = i;
            while (j > 0 && seasonStartYears[j - 1] > startYear) {
                seasonIds[j] = seasonIds[j - 1];
                seasonStartYears[j] = seasonStartYears[j - 1];
                unchecked {
                    --j;
                }
            }
            seasonIds[j] = id;
            seasonStartYears[j] = startYear;
        }
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
