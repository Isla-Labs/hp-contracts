// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { RegistryErrors as Errors } from "@errors/registries/RegistryErrors.sol";
import { RegistryEvents as Events } from "@events/registries/RegistryEvents.sol";
import { Hub, Season, Tournament, TournamentType, RoundSchedule } from "@types/registries/TournamentTypes.sol";
import { RoundStatus } from "@types/vaults/VaultTypes.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { IPbrFeeHub } from "@interfaces/markets/IPbrFeeHub.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";
import { IPlayerVault } from "@interfaces/vaults/IPlayerVault.sol";

/**
 * @title TournamentRegistry
 * @notice Canonical tournament topology, season calendars, and vault membership SoT.
 * @dev Examples:
 *        - `EPL`: DOMESTIC_LEAGUE, feeHubs = [{EPL, hub}], treasury = EPL pot
 *        - `FACUP`: DOMESTIC_CUP, feeHubs = [{EPL, hub}], treasury = FA Cup pot
 *        - `UCL`: CONTINENTAL, feeHubs = all domestic hubs, treasury = UCL pot
 *
 *      Access:
 *      - Owner (`Orchestrator`): `registerHub`, tournament create, `linkHub`, vault membership,
 *        and season calendar (`openSeason` / `upsertRound(s)`).
 *      - `PlayerSetRegistry`: vault register/unregister fan-out.
 *      - Tournament `PbrTreasury`: `flushPendingUnregisters` after settle.
 *
 *      Non-`DOMESTIC_LEAGUE` create / `linkHub` dual-writes the tournament treasury onto each
 *      linked `PbrFeeHub` destination list (`setDomesticCups` / `setContinental` /
 *      `setInternational`). League hubs own their `leagueTreasury` at hub init.
 *
 *      Vault membership is the SoT here; each write syncs local caches on the tournament's
 *      `PbrTreasury` and the vault's active-treasury list. Unregister while the treasury active
 *      round is `Locked` is deferred until settle so SettlePbr still observes the vault through
 *      distribute.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TournamentRegistry is Initializable, AddressBook, Ownable, ITournamentRegistry {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    IPlayerSetRegistry public playerSetRegistry;

    /// @notice Globally registered domestic hubs (`leagueId` → hub). Used by FeeRouter OOF split.
    mapping(bytes32 leagueId => address) public pbrFeeHubOf;
    bytes32[] private _leagueIds;

    mapping(bytes32 tournamentId => Tournament) private _tournaments;
    bytes32[] private _tournamentIds;

    /// @notice Global reverse index: SP calendar `seasonId` → `tournamentId` (written in `openSeason`).
    /// @dev For `DOMESTIC_LEAGUE`, value equals `leagueId`. Unique across all tournaments.
    mapping(bytes32 seasonId => bytes32 tournamentId) public tournamentIdOfSeason;

    /// @dev SoT vault set per tournament (mirrored to `PbrTreasury` cache on write).
    mapping(bytes32 tournamentId => address[]) private _registeredVaults;
    mapping(bytes32 tournamentId => mapping(address vault => uint256)) private _registeredVaultIndex; // 1-based
    mapping(bytes32 tournamentId => mapping(address vault => bool)) private _isVaultRegistered;

    /// @dev Deferred removals while treasury active round is `Locked` (SoT + cache stay until flush).
    mapping(bytes32 tournamentId => address[]) private _pendingUnregister;
    mapping(bytes32 tournamentId => mapping(address vault => uint256)) private _pendingUnregisterIndex; // 1-based

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    /// @notice Transfers ownership to `Orchestrator` and resolves `PlayerSetRegistry` from `AddressProvider` once.
    function initialize() external initializer {
        _transferOwnership(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));
        playerSetRegistry = IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));
    }

    // --------------------------------------------
    //  Domestic hubs (FeeRouter) — owner
    // --------------------------------------------

    /**
     * @notice Registers a domestic league hub (`leagueId` + `PbrFeeHub` address).
     * @dev Used only when deploying a new DOMESTIC_LEAGUE (other types use existing league hubs):
     *      STEP1: call registerHub
     *      STEP2: call createTournament
     */
    function registerHub(Hub calldata hub) external onlyOwner {
        if (hub.leagueId == bytes32(0)) revert Errors.ZeroId();
        if (hub.pbrFeeHub == address(0)) revert Errors.ZeroAddress();
        if (pbrFeeHubOf[hub.leagueId] != address(0)) revert Errors.HubAlreadyRegistered(hub.leagueId);

        pbrFeeHubOf[hub.leagueId] = hub.pbrFeeHub;
        _leagueIds.push(hub.leagueId);
        emit Events.HubRegistered(hub.leagueId, hub.pbrFeeHub);
    }

    // --------------------------------------------
    //  Tournament registration — owner
    // --------------------------------------------

    /**
     * @notice Creates a tournament with linked fee hubs and treasury.
     * @param tournamentId Stable id (e.g. keccak256("EPL"), keccak256("UCL")).
     *      For `DOMESTIC_LEAGUE`, must equal the `leagueId` previously passed to `registerHub`.
     * @param tournamentType Domestic league / domestic cup / continental / international.
     * @param feeHubs Domestic hubs that should route fees to `pbrTreasury` (must be registered).
     * @param pbrTreasury Tournament-specific `PbrTreasury` (required; deploy alongside the tournament).
     * @dev For non-league types, each linked hub also receives `pbrTreasury` on its typed
     *      destination list (cup / continental / international).
     */
    function createTournament(
        bytes32 tournamentId,
        TournamentType tournamentType,
        Hub[] calldata feeHubs,
        address pbrTreasury
    ) external onlyOwner {
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
     *      include its hub. Also appends this tournament's treasury onto the hub's continental /
     *      international destination list. Domestic leagues/cups get their hub only at
     *      `createTournament`.
     */
    function linkHub(bytes32 tournamentId, Hub calldata hub) external onlyOwner {
        Tournament storage t = _requireTournament(tournamentId);
        TournamentType tournamentType = t.tournamentType;
        if (tournamentType != TournamentType.CONTINENTAL && tournamentType != TournamentType.INTERNATIONAL) {
            revert Errors.InvalidLinkTarget(tournamentType);
        }
        _linkHub(t, tournamentId, hub);
    }

    // --------------------------------------------
    //  Vault membership SoT — owner
    // --------------------------------------------

    /// @inheritdoc ITournamentRegistry
    function registerVaults(bytes32 tournamentId, address[] calldata vaults) external {
        _checkVaultMembershipCaller();
        Tournament storage t = _requireTournament(tournamentId);
        address treasury = t.pbrTreasury;
        uint256 length = vaults.length;
        for (uint256 i; i < length; ++i) {
            address vault = vaults[i];
            // Cancel deferred removal — vault stays registered for the locked round.
            if (_cancelPendingUnregister(tournamentId, vault)) continue;
            _registerVault(tournamentId, treasury, vault);
        }
    }

    /// @inheritdoc ITournamentRegistry
    function unregisterVaults(bytes32 tournamentId, address[] calldata vaults) external {
        _checkVaultMembershipCaller();
        Tournament storage t = _requireTournament(tournamentId);
        address treasury = t.pbrTreasury;
        bool locked = _isTreasuryActiveRoundLocked(treasury);
        uint256 length = vaults.length;
        for (uint256 i; i < length; ++i) {
            address vault = vaults[i];
            if (locked) {
                _queuePendingUnregister(tournamentId, vault);
            } else {
                _unregisterVault(tournamentId, treasury, vault);
            }
        }
    }

    /// @inheritdoc ITournamentRegistry
    function flushPendingUnregisters(bytes32 tournamentId) external {
        Tournament storage t = _requireTournament(tournamentId);
        if (msg.sender != t.pbrTreasury && msg.sender != owner()) revert Errors.NotAuthorized();
        // Settle must have moved the round out of `Locked` before flush.
        if (_isTreasuryActiveRoundLocked(t.pbrTreasury)) revert Errors.RoundStillLocked(tournamentId);

        address[] storage pending = _pendingUnregister[tournamentId];
        uint256 count = pending.length;
        address treasury = t.pbrTreasury;
        while (pending.length != 0) {
            address vault = pending[pending.length - 1];
            pending.pop();
            delete _pendingUnregisterIndex[tournamentId][vault];
            if (_isVaultRegistered[tournamentId][vault]) {
                _unregisterVault(tournamentId, treasury, vault);
            }
        }
        if (count != 0) emit Events.VaultUnregisterFlushed(tournamentId, count);
    }

    /// @dev Owner or `PlayerSetRegistry` (lifecycle SoT fan-out).
    function _checkVaultMembershipCaller() internal view {
        if (msg.sender == owner()) return;
        if (msg.sender == address(playerSetRegistry)) return;
        revert Errors.NotAuthorized();
    }

    // --------------------------------------------
    //  Season calendar — owner
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
    ) external onlyOwner {
        if (seasonId == bytes32(0) || seasonStartYear == 0) revert Errors.ZeroId();
        if (finalRound == 0) revert Errors.InvalidFinalRound();

        Tournament storage t = _requireTournament(tournamentId);
        if (_seasonIndex(t, seasonStartYear) != type(uint256).max) {
            revert Errors.SeasonExists(tournamentId, seasonStartYear);
        }

        bytes32 existing = tournamentIdOfSeason[seasonId];
        if (existing != bytes32(0)) revert Errors.SeasonIdTaken(seasonId, existing);
        tournamentIdOfSeason[seasonId] = tournamentId;

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
        if (t.tournamentType == TournamentType.DOMESTIC_LEAGUE) {
            emit Events.DomesticSeasonOpened(tournamentId, seasonId, seasonStartYear);
        }
    }

    function upsertRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        RoundSchedule calldata round
    ) external onlyOwner {
        _upsertRound(tournamentId, seasonStartYear, round);
    }

    /// @notice Bulk `upsertRound` for calendar bootstrap / matchweek ingest.
    function upsertRounds(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        RoundSchedule[] calldata rounds
    ) external onlyOwner {
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

    /// @inheritdoc ITournamentRegistry
    function tournamentExists(bytes32 tournamentId) external view returns (bool) {
        return _tournaments[tournamentId].tournamentId != bytes32(0);
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
    function isVaultUnregisterPending(bytes32 tournamentId, address vault) external view returns (bool) {
        return _pendingUnregisterIndex[tournamentId][vault] != 0;
    }

    /// @inheritdoc ITournamentRegistry
    function getRegisteredVaults(bytes32 tournamentId) external view returns (address[] memory) {
        _requireTournament(tournamentId);
        return _registeredVaults[tournamentId];
    }

    /// @inheritdoc ITournamentRegistry
    function isLeagueLinkedToTournament(bytes32 tournamentId, bytes32 leagueId) external view returns (bool) {
        if (leagueId == bytes32(0) || _tournaments[tournamentId].tournamentId == bytes32(0)) return false;
        // Domestic league: tournament id equals league id.
        if (tournamentId == leagueId) return true;

        Hub[] storage feeHubs = _tournaments[tournamentId].feeHubs;
        uint256 n = feeHubs.length;
        for (uint256 i; i < n; ++i) {
            if (feeHubs[i].leagueId == leagueId) return true;
        }
        return false;
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
     * @dev CRE `eligibility-store` uses this on `DomesticLeagueCreated` / `DomesticSeasonOpened`
     *      to `SYNC_LEAGUE` into EligibilityStore's RunBook (domestic leagues only).
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

        // League hubs already hold `leagueTreasury` from init; non-league destinations dual-write here.
        if (t.tournamentType != TournamentType.DOMESTIC_LEAGUE) {
            _appendTreasuryToHub(hub.pbrFeeHub, t.tournamentType, t.pbrTreasury);
        }
    }

    /// @dev Append `treasury` to the hub list matching `tournamentType` (full replace via hub setters).
    function _appendTreasuryToHub(address hubAddr, TournamentType tournamentType, address treasury) internal {
        IPbrFeeHub hub = IPbrFeeHub(hubAddr);
        if (tournamentType == TournamentType.DOMESTIC_CUP) {
            hub.setDomesticCups(_appendAddress(hub.getDomesticCups(), treasury));
        } else if (tournamentType == TournamentType.CONTINENTAL) {
            hub.setContinental(_appendAddress(hub.getContinental(), treasury));
        } else if (tournamentType == TournamentType.INTERNATIONAL) {
            hub.setInternational(_appendAddress(hub.getInternational(), treasury));
        } else {
            revert Errors.InvalidLinkTarget(tournamentType);
        }
    }

    function _appendAddress(address[] memory existing, address added) internal pure returns (address[] memory next) {
        uint256 length = existing.length;
        next = new address[](length + 1);
        for (uint256 i; i < length; ++i) {
            next[i] = existing[i];
        }
        next[length] = added;
    }

    function _isTreasuryActiveRoundLocked(address treasury) private view returns (bool) {
        if (treasury == address(0)) return false;
        (uint16 seasonStartYear, uint32 active,) = IPbrTreasury(treasury).getCursors();
        RoundStatus status = IPbrTreasury(treasury).getRound(seasonStartYear, active).status;
        // Defer lifecycle unregisters until Claimable (through per-fixture settle).
        return status == RoundStatus.Locked || status == RoundStatus.SettlePending;
    }

    function _queuePendingUnregister(bytes32 tournamentId, address vault) private {
        if (!_isVaultRegistered[tournamentId][vault]) revert Errors.VaultNotRegistered(tournamentId, vault);
        if (_pendingUnregisterIndex[tournamentId][vault] != 0) return;

        _pendingUnregister[tournamentId].push(vault);
        _pendingUnregisterIndex[tournamentId][vault] = _pendingUnregister[tournamentId].length;
        emit Events.VaultUnregisterPending(tournamentId, vault);
    }

    /// @return cancelled True if a deferred unregister was cleared (vault remains registered).
    function _cancelPendingUnregister(bytes32 tournamentId, address vault) private returns (bool cancelled) {
        uint256 index1 = _pendingUnregisterIndex[tournamentId][vault];
        if (index1 == 0) return false;

        address[] storage pending = _pendingUnregister[tournamentId];
        uint256 index0 = index1 - 1;
        uint256 last = pending.length - 1;
        if (index0 != last) {
            address moved = pending[last];
            pending[index0] = moved;
            _pendingUnregisterIndex[tournamentId][moved] = index0 + 1;
        }
        pending.pop();
        delete _pendingUnregisterIndex[tournamentId][vault];
        return true;
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

        // Vault cache first so treasury register / live utilization sync sees membership.
        IPlayerVault(vault).syncActiveTreasury(tournamentId, treasury, true);
        IPbrTreasury(treasury).syncRegisterVault(vault);
    }

    function _unregisterVault(bytes32 tournamentId, address treasury, address vault) private {
        if (!_isVaultRegistered[tournamentId][vault]) revert Errors.VaultNotRegistered(tournamentId, vault);

        // Drop any deferred entry if flushing / immediate path races.
        _cancelPendingUnregister(tournamentId, vault);

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
        IPlayerVault(vault).syncActiveTreasury(tournamentId, treasury, false);
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
