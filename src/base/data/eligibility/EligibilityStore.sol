// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { IReceiver } from "@cre/v1/interfaces/IReceiver.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { CreReceiver } from "@base/abstract/CreReceiver.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";
import { Position } from "@types/PlayerSetTypes.sol";

import { EligibilityErrors as Errors } from "@errors/data/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@events/data/EligibilityEvents.sol";
import {
    Appearance,
    LAMBDA_WAD,
    LeagueMinutes,
    MinutesStore,
    POSITION_COUNT,
    VerifySnapshot,
    PassKind,
    RunBook,
    RunStatus,
    SCORE_WAD,
    SORT_STEP_REMOVALS,
    SORT_STEP_UPSERT,
    SQUAD_FETCH_PAGE_DONE,
    SeasonRun,
    SortCursor,
    SquadList,
    SquadPhase,
    SquadReport,
    SquadWorkflowEvents as WorkflowEvents,
    TransientReturn,
    WorkflowControl
} from "./types/EligibilityTypes.sol";

/**
 * @title EligibilityStore
 * @notice Standalone data plane: CRE squads workflow + PpmVerifier appearance ingest.
 * @dev Deployed behind its own proxy (EIP-170). Two write paths (no eligibility thresholds /
 *      cohort routing — those live on `EligibilityVerifier`):
 *
 *      1) CRE `SquadReport` → `_processReport` (FETCH / SORT / SYNC)
 *      2) PpmVerifier → `recordAppearances` (career `positionMinutes` + per-league score)
 *
 *      Privileged verify helpers (`purgeIfStale` / `syncPlayerScore` / `takePending*`) are
 *      callable only by `eligibilityVerifier`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract EligibilityStore is Initializable, AddressBook, Ownable, CreReceiver {
    // --------------------------------------------
    //  Constants
    // --------------------------------------------

    /// @dev Players upserted / removal candidates processed per SORT execution.
    uint256 internal constant SORT_CHUNK = 50;

    /// @dev Max `(leagueId, year)` final-round entries cached in one appearance batch.
    uint256 internal constant _FINAL_ROUND_CACHE_CAP = 16;

    /// @dev Drop `MinutesStore` rows with `deactivatedAt` at least this old (verify GC).
    uint256 internal constant STALE_AFTER = 5 * 365 days;

    // --------------------------------------------
    //  Wiring
    // --------------------------------------------

    /// @notice Sole caller for verify-page mutations (`purgeIfStale` / score sync / pending drains).
    address public eligibilityVerifier;

    // --------------------------------------------
    //  Storage — workflow
    // --------------------------------------------

    WorkflowControl internal _control;
    RunBook internal _runBook;
    TransientReturn internal _transient;
    SortCursor internal _sortCursor;

    /// @dev Leagues fully backfilled. Historical resume pointer when a pass ends.
    uint16 internal _backfilledLeagues;

    /// @notice When the last current-season pass finished (CRE cron throttle input).
    uint64 public lastCurrentPassCompletedAt;

    mapping(bytes32 leagueId => bool) internal _leagueQueued;

    // --------------------------------------------
    //  Storage — persistent squad / minutes data
    // --------------------------------------------

    mapping(bytes32 playerId => MinutesStore) internal _minutesStore;

    bytes32[] internal _playerIds;
    mapping(bytes32 playerId => bool) internal _tracked;

    mapping(bytes32 clubId => SquadList) internal _squadLists;

    /// @dev Last `seasonId` that rebuilt a club's `SquadList`.
    mapping(bytes32 clubId => bytes32 seasonId) internal _clubSquadSeason;

    /// @dev Clubs present in the latest fully-sorted season for a league (pruned each SORT).
    mapping(bytes32 leagueId => bytes32[] clubIds) internal _leagueClubs;
    mapping(bytes32 leagueId => mapping(bytes32 clubId => bool)) internal _leagueClubKnown;

    /// @dev Stamp: player appeared in the season buffer during the in-flight SORT upsert.
    mapping(bytes32 playerId => bytes32 seasonId) internal _lastSeasonSeen;

    /// @dev Prior-roster players staged during SquadList rebuilds + untouched clubs.
    bytes32[] internal _removalCandidates;
    mapping(bytes32 playerId => bool) internal _removalCandidateQueued;

    /// @dev SORT change buckets — drained by the verifier later (events still emitted).
    bytes32[] internal _pendingLeftLeague;
    bytes32[] internal _pendingClubChanged;
    bytes32[] internal _pendingLeagueChanged;

    /// @dev Seasons appended while a pass was active — woken via `SeasonReady` as soon as
    ///      the store returns to `_idleOrResume` (no cron wait). Parallel arrays.
    bytes32[] internal _deferredWakeLeagueIds;
    bytes32[] internal _deferredWakeSeasonIds;

    // --------------------------------------------
    //  Storage — score clock
    // --------------------------------------------

    /// @notice G-index origin season start year (fixed after init). Distinct from
    ///         `WorkflowControl.currentSeasonStartYear` (cron / finalize classification).
    uint16 public scoreBaseYear;

    /// @dev Tx-local cache: `TournamentRegistry.getFinalRound(leagueId, year)`.
    struct FinalRoundCache {
        bytes32[_FINAL_ROUND_CACHE_CAP] leagueIds;
        uint16[_FINAL_ROUND_CACHE_CAP] seasonYears;
        uint32[_FINAL_ROUND_CACHE_CAP] finals;
        uint8 len;
    }

    // --------------------------------------------
    //  Construction / init
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider`.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    /**
     * @notice Proxy init: ownership, CRE forwarder + workflow id, year clocks, verifier wire.
     * @param workflowId_ Expected CRE workflow id (squads `eligibility-store`).
     * @param baseYear_ Sets `scoreBaseYear` (G-index origin) and initial `currentSeasonStartYear`.
     * @param eligibilityVerifier_ `EligibilityVerifier` proxy (verify-page privileged caller).
     */
    function initialize(bytes32 workflowId_, uint16 baseYear_, address eligibilityVerifier_) external initializer {
        if (workflowId_ == bytes32(0)) revert Errors.ZeroWorkflowId();
        if (baseYear_ == 0) revert Errors.ZeroId();
        if (eligibilityVerifier_ == address(0)) revert Errors.ZeroAddress();

        address forwarder_ = _getAddress(_addressKey(Addresses.CRE_FORWARDER));

        _transferOwnership(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));

        eligibilityVerifier = eligibilityVerifier_;

        __CreReceiver_init(forwarder_);
        _setExpectedWorkflowId(workflowId_);
        _setScoreBaseYear(baseYear_);
        _setCurrentSeasonStartYear(baseYear_);
    }

    modifier onlyVerifier() {
        if (msg.sender != eligibilityVerifier) revert Errors.Unauthorized();
        _;
    }

    // --------------------------------------------
    //  Ops — owner (Orchestrator)
    // --------------------------------------------

    /// @notice Manually queue a league's seasons (oldest→newest). Prefer CRE `SYNC_LEAGUE`.
    function queueLeague(
        bytes32 leagueId,
        bytes32[] calldata seasonIds,
        uint16[] calldata seasonStartYears
    ) external onlyOwner {
        _queueLeague(leagueId, seasonIds, seasonStartYears);
    }

    /// @notice Set / retune `currentSeasonStartYear` while idle (monotonic tick usually via finalize).
    function setCurrentSeasonStartYear(uint16 year) external onlyOwner {
        _setCurrentSeasonStartYear(year);
    }

    function setExpectedWorkflowId(bytes32 workflowId_) external onlyOwner {
        if (workflowId_ == bytes32(0)) revert Errors.ZeroWorkflowId();
        _setExpectedWorkflowId(workflowId_);
    }

    function setForwarderAddress(address forwarder_) external onlyOwner {
        _setForwarderAddress(forwarder_);
    }

    // --------------------------------------------
    //  Privileged — EligibilityVerifier verify page
    // --------------------------------------------

    /**
     * @notice If `deactivatedAt` is set and at least `STALE_AFTER` old, purge the row.
     * @dev Returns true when the slot was purged (caller must not advance page index).
     */
    function purgeIfStale(uint256 index) external onlyVerifier returns (bool purged) {
        if (index >= _playerIds.length) return false;
        MinutesStore storage store = _minutesStore[_playerIds[index]];
        uint64 deactivatedAt = store.deactivatedAt;
        if (deactivatedAt == 0) return false;
        if (block.timestamp < uint256(deactivatedAt) + STALE_AFTER) return false;
        _purgePlayerAt(index);
        return true;
    }

    /// @notice Idle-decay one player's `currentLeagueId` score to that league's `G_now`.
    function syncPlayerScore(bytes32 playerId) external onlyVerifier {
        _syncPlayerScore(playerId);
    }

    /**
     * @notice Sync `currentLeagueId` score to `G_now`, then return a lean classify snapshot.
     * @dev Single external call for the verify page — avoids copying full `MinutesStore`.
     */
    function syncAndSnapshot(bytes32 playerId) external onlyVerifier returns (VerifySnapshot memory snap) {
        _syncPlayerScore(playerId);
        return _verifySnapshot(playerId);
    }

    /// @notice Lean classify view: scalars + `LeagueMinutes` for `currentLeagueId` only.
    function getVerifySnapshot(bytes32 playerId) external view returns (VerifySnapshot memory) {
        return _verifySnapshot(playerId);
    }

    /// @notice Snapshot + clear staged league-leavers for TransferLocker handoff.
    function takePendingLeftLeague() external onlyVerifier returns (bytes32[] memory ids) {
        return _takePendingLeftLeague();
    }

    /// @notice Snapshot + clear staged club movers.
    function takePendingClubChanged() external onlyVerifier returns (bytes32[] memory ids) {
        return _takePendingClubChanged();
    }

    /// @notice Snapshot + clear staged league movers.
    function takePendingLeagueChanged() external onlyVerifier returns (bytes32[] memory ids) {
        return _takePendingLeagueChanged();
    }

    // --------------------------------------------
    //  Views — workflow
    // --------------------------------------------

    function workflowControl() external view returns (WorkflowControl memory) {
        return _control;
    }

    function runNumber() external view returns (uint16) {
        return _runBook.runNumber;
    }

    function leagueCount() external view returns (uint256) {
        return _runBook.leagueIds.length;
    }

    function leagueIdAt(uint256 leagueIndex) external view returns (bytes32) {
        return _runBook.leagueIds[leagueIndex];
    }

    function leagueSeasons(uint256 leagueIndex) external view returns (SeasonRun[] memory) {
        return _runBook.seasons[leagueIndex];
    }

    /// @notice Compact staging-buffer status (avoids copying parallel arrays).
    function transientStatus()
        external
        view
        returns (
            bytes32 leagueId,
            bytes32 seasonId,
            uint16 pageFetched,
            uint16 nextPage,
            uint16 personsOffset,
            uint256 stagedPlayers
        )
    {
        TransientReturn storage buf = _transient;
        return (buf.leagueId, buf.seasonId, buf.pageFetched, buf.nextPage, buf.personsOffset, buf.playerIds.length);
    }

    function sortCursor() external view returns (SortCursor memory) {
        return _sortCursor;
    }

    /// @notice League-leavers staged by SORT, not yet handed to TransferLocker.
    function pendingLeftLeagueCount() external view returns (uint256) {
        return _pendingLeftLeague.length;
    }

    /// @notice Intra-league club movers staged by SORT upsert.
    function pendingClubChangedCount() external view returns (uint256) {
        return _pendingClubChanged.length;
    }

    /// @notice Cross-league movers staged by SORT upsert.
    function pendingLeagueChangedCount() external view returns (uint256) {
        return _pendingLeagueChanged.length;
    }

    /**
     * @notice CRE cron gate: next `IDLE` season for `currentSeasonStartYear`, if a pass may start.
     * @dev Year equality is required — historical leftovers must be `ARTIFACT`, not cron fodder.
     *      Pair with `lastCurrentPassCompletedAt` for the daily-resweep throttle.
     */
    function nextCurrentSeason() external view returns (bool ready, bytes32 leagueId, bytes32 seasonId) {
        if (_control.pass != PassKind.None || _control.currentSeasonStartYear == 0) {
            return (false, bytes32(0), bytes32(0));
        }
        (bool found, uint16 li, uint16 si) = _findIdleSeason(0, 0);
        if (!found) return (false, bytes32(0), bytes32(0));
        return (true, _runBook.leagueIds[li], _runBook.seasons[li][si].seasonId);
    }

    // --------------------------------------------
    //  Views — persistent data
    // --------------------------------------------

    function playerCount() external view returns (uint256) {
        return _playerIds.length;
    }

    function playerIdAt(uint256 index) external view returns (bytes32) {
        return _playerIds[index];
    }

    function playerIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory out) {
        uint256 total = _playerIds.length;
        if (offset >= total || limit == 0) {
            return new bytes32[](0);
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

        uint256 n = end - offset;
        out = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = _playerIds[offset + i];
        }
    }

    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory) {
        return _minutesStore[playerId];
    }

    /// @dev Build verify snapshot; `currentLeague` zeroed when no row for `currentLeagueId`.
    function _verifySnapshot(bytes32 playerId) private view returns (VerifySnapshot memory snap) {
        MinutesStore storage store = _minutesStore[playerId];
        snap.currentLeagueId = store.currentLeagueId;
        snap.currentClubId = store.currentClubId;
        snap.birthDate = store.birthDate;
        snap.startYearCurrentLeague = store.startYearCurrentLeague;
        snap.expectedPosition = store.expectedPosition;

        if (snap.currentLeagueId == bytes32(0)) return snap;
        uint256 lmIndex = _leagueMinutesIndex(store, snap.currentLeagueId);
        if (lmIndex == type(uint256).max) return snap;
        snap.currentLeague = store.leagueMinutes[lmIndex];
    }

    /// @dev Idle-decay `currentLeagueId` score to `G_now` (no-op when nothing to sync).
    function _syncPlayerScore(bytes32 playerId) private {
        MinutesStore storage store = _minutesStore[playerId];
        bytes32 leagueId = store.currentLeagueId;
        if (leagueId == bytes32(0)) return;

        uint256 lmIndex = _leagueMinutesIndex(store, leagueId);
        if (lmIndex == type(uint256).max) return;

        LeagueMinutes storage lm = store.leagueMinutes[lmIndex];
        uint32 last = lm.lastScoreGlobalRound;
        if (last == 0 || lm.weightedScoreWad == 0) return;

        FinalRoundCache memory frCache;
        uint32 gNow = _globalRoundNow(leagueId, frCache);
        if (gNow <= last) return;

        _syncLeagueScoreToNow(lm, gNow);
        emit Events.WeightedScoreUpdated(playerId, leagueId, lm.weightedScoreWad);
    }

    /// @notice Name/symbol only — avoids copying `positionMinutes` / `leagueMinutes`.
    function getPlayerMetadata(bytes32 playerId)
        external
        view
        returns (string memory name, string memory symbol, bool metadataSet)
    {
        MinutesStore storage store = _minutesStore[playerId];
        name = store.name;
        symbol = store.symbol;
        metadataSet = bytes(name).length != 0;
    }

    function getSquadList(bytes32 clubId) external view returns (SquadList memory) {
        return _squadLists[clubId];
    }

    function isTracked(bytes32 playerId) external view returns (bool) {
        return _tracked[playerId];
    }

    // --------------------------------------------
    //  Minutes ingest (PpmVerifier)
    // --------------------------------------------

    /**
     * @notice Ingest match minutes; update career position aggregates and league scores.
     * @dev Squad SORT must have created the `MinutesStore` already. Per-match rows are not
     *      stored. Domestic-league calendars in the RunBook incrementally update that
     *      league's `LeagueMinutes`; `verifyEligibility` only decays aggregates to `G_now`.
     * @param seasonId Tournament calendar HPID for this batch.
     * @param seasonStartYear Calendar year used with `roundNumber` for the G-index.
     * @param appearances Match deltas (may mix leagues; scoring is per `appearance.leagueId`).
     */
    function recordAppearances(bytes32 seasonId, uint16 seasonStartYear, Appearance[] calldata appearances) external {
        if (msg.sender != _ppmVerifier()) revert Errors.Unauthorized();
        if (seasonId == bytes32(0) || seasonStartYear == 0) revert Errors.ZeroId();

        FinalRoundCache memory frCache;
        uint256 length = appearances.length;

        for (uint256 i; i < length; ++i) {
            Appearance calldata appearance = appearances[i];
            if (appearance.playerId == bytes32(0) || appearance.leagueId == bytes32(0) || appearance.roundNumber == 0) {
                revert Errors.ZeroId();
            }
            if (appearance.minsPlayed == 0) continue;
            if (!_tracked[appearance.playerId]) revert Errors.UnknownPlayer(appearance.playerId);

            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 posIndex = uint256(uint8(appearance.position));
            if (posIndex >= POSITION_COUNT) revert Errors.ZeroId();

            MinutesStore storage store = _minutesStore[appearance.playerId];
            uint32 cumulative = _accumulatePosition(store, posIndex, appearance.minsPlayed);

            if (_isScoringSeason(appearance.leagueId, seasonId, seasonStartYear)) {
                LeagueMinutes storage lm = _getOrCreateLeagueMinutes(store, appearance.leagueId);
                _applyAppearanceScore(
                    lm, appearance.leagueId, seasonStartYear, appearance.roundNumber, appearance.minsPlayed, frCache
                );
                emit Events.WeightedScoreUpdated(appearance.playerId, appearance.leagueId, lm.weightedScoreWad);
            }

            emit Events.MinutesUpdated(
                appearance.playerId,
                seasonId,
                appearance.roundNumber,
                appearance.position,
                appearance.minsPlayed,
                cumulative,
                store.expectedPosition
            );
        }

        emit Events.AppearancesRecorded(length);
    }

    // --------------------------------------------
    //  CRE fulfill — phase dispatch
    // --------------------------------------------

    /// @inheritdoc CreReceiver
    function _processReport(bytes calldata, bytes calldata report) internal override {
        SquadReport memory r = abi.decode(report, (SquadReport));

        if (r.phase == SquadPhase.SYNC_LEAGUE) {
            if (r.leagueId == bytes32(0)) revert Errors.ZeroId();
            _syncLeague(r.leagueId, r.syncSeasonIds, r.syncSeasonYears);
            return;
        }

        if (r.leagueId == bytes32(0) || r.seasonId == bytes32(0)) revert Errors.ZeroId();

        if (r.phase == SquadPhase.FETCH_TRANSIENT) {
            _fetchTransient(r);
        } else if (r.phase == SquadPhase.SORT_TRANSIENT) {
            _sortTransient(r);
        } else {
            revert Errors.UnknownSquadPhase();
        }
    }

    // --------------------------------------------
    //  Phase 0 — SYNC_LEAGUE (RunBook ↔ TournamentRegistry)
    // --------------------------------------------

    /**
     * @dev CRE Trigger 1 / SeasonOpened: reconcile registry seasons into the RunBook.
     *      First sync queues the league (starts historical if idle); later syncs append
     *      only seasons newer than the last queued year (monotonic).
     */
    function _syncLeague(bytes32 leagueId, bytes32[] memory seasonIds, uint16[] memory seasonStartYears) private {
        if (!_leagueQueued[leagueId]) {
            _queueLeague(leagueId, seasonIds, seasonStartYears);
            return;
        }

        uint256 n = seasonIds.length;
        if (n != seasonStartYears.length) revert Errors.LengthMismatch(n, seasonStartYears.length);

        // Map existing seasons for idempotent re-sync.
        uint256 leagueIndex = _leagueIndex(leagueId);
        SeasonRun[] storage rows = _runBook.seasons[leagueIndex];
        uint16 lastYear = rows.length == 0 ? 0 : rows[rows.length - 1].seasonStartYear;

        for (uint256 i; i < n; ++i) {
            bytes32 seasonId = seasonIds[i];
            uint16 year = seasonStartYears[i];
            if (seasonId == bytes32(0) || year == 0) revert Errors.ZeroId();
            if (_seasonQueued(leagueIndex, seasonId)) continue;
            if (year <= lastYear) revert Errors.SeasonsNotAscending();
            _appendSeason(leagueIndex, seasonId, year);
            lastYear = year;
        }
    }

    // --------------------------------------------
    //  Phase 1 — FETCH_TRANSIENT
    // --------------------------------------------

    /**
     * @dev Appends one SP page-slice. Stay-on-page drains a club across reports via
     *      `personsOffset`; `_pgNm` only advances when CRE marks the club complete
     *      (`nextPage != pageFetched`) or the season `DONE`.
     */
    function _fetchTransient(SquadReport memory r) private {
        WorkflowControl storage c = _control;

        if (c.pass == PassKind.None) {
            _startCurrentPass(r.leagueId, r.seasonId);
        } else if (r.leagueId != c.activeLeagueId || r.seasonId != c.activeSeasonId) {
            revert Errors.NotActiveSeason(r.leagueId, r.seasonId);
        }

        SeasonRun storage row = _activeSeasonRow();
        if (row.status != RunStatus.IDLE) revert Errors.SeasonNotFetchable(r.seasonId);

        TransientReturn memory page = r.data;
        if (page.leagueId != r.leagueId || page.seasonId != r.seasonId) {
            revert Errors.TransientSeasonMismatch(r.seasonId, page.seasonId);
        }

        uint16 pageFetched = page.pageFetched;
        uint16 nextPage = page.nextPage;
        if (pageFetched == 0 || pageFetched >= SQUAD_FETCH_PAGE_DONE) {
            revert Errors.InvalidNextPage(pageFetched, nextPage);
        }
        // Stay-on-page, advance one SP page, or DONE — never rewind / skip ahead.
        if (!(nextPage == pageFetched || nextPage == pageFetched + 1 || nextPage == SQUAD_FETCH_PAGE_DONE)) {
            revert Errors.InvalidNextPage(pageFetched, nextPage);
        }

        TransientReturn storage buf = _transient;
        if (buf.seasonId != r.seasonId) {
            // First slice of the active season. Non-empty slot ⇒ prior season never sorted.
            if (buf.seasonId != bytes32(0)) revert Errors.TransientSeasonMismatch(buf.seasonId, r.seasonId);
            if (pageFetched != 1) revert Errors.FetchPageMismatch(r.seasonId, 1, pageFetched);
            if (page.personsOffset != 0) revert Errors.FetchOffsetMismatch(r.seasonId, 0, page.personsOffset);
            buf.leagueId = r.leagueId;
            buf.seasonId = r.seasonId;
            buf.seasonStartYear = row.seasonStartYear;
            buf.pageFetched = 1;
            buf.nextPage = 1;
            buf.personsOffset = 0;
        } else {
            // Resume: either stay on `pageFetched` or open the page advertised by `nextPage`.
            uint16 expectedPage = buf.nextPage == buf.pageFetched ? buf.pageFetched : buf.nextPage;
            if (pageFetched != expectedPage) {
                revert Errors.FetchPageMismatch(r.seasonId, expectedPage, pageFetched);
            }
            if (page.personsOffset != buf.personsOffset) {
                revert Errors.FetchOffsetMismatch(r.seasonId, buf.personsOffset, page.personsOffset);
            }
        }

        uint256 appended = _appendPage(buf, page);
        // Stay-on-page with an empty slice cannot make progress and would loop forever.
        if (nextPage == pageFetched && appended == 0) revert Errors.InvalidNextPage(pageFetched, nextPage);

        uint256 newOffset = uint256(buf.personsOffset) + appended;
        if (newOffset > type(uint16).max) revert Errors.InvalidNextPage(pageFetched, nextPage);
        // forge-lint: disable-next-line(unsafe-typecast)
        buf.personsOffset = uint16(newOffset);
        buf.pageFetched = pageFetched;
        buf.nextPage = nextPage;

        if (nextPage != pageFetched) {
            // Club fully drained (advance) or season DONE — reset within-page cursor.
            buf.personsOffset = 0;
        }

        if (nextPage == SQUAD_FETCH_PAGE_DONE) {
            row.status = RunStatus.TRANSIENT;
            emit WorkflowEvents.TransientComplete(r.leagueId, r.seasonId);
        } else {
            emit WorkflowEvents.FetchContinue(r.leagueId, r.seasonId, nextPage, buf.personsOffset);
        }
    }

    /// @dev Validates and appends one page slice's parallel arrays. Returns row count.
    function _appendPage(TransientReturn storage buf, TransientReturn memory page) private returns (uint256 n) {
        n = page.playerIds.length;
        if (page.clubIds.length != n) revert Errors.LengthMismatch(n, page.clubIds.length);
        if (page.playerNames.length != n) revert Errors.LengthMismatch(n, page.playerNames.length);
        if (page.playerSymbols.length != n) revert Errors.LengthMismatch(n, page.playerSymbols.length);
        if (page.birthDates.length != n) revert Errors.LengthMismatch(n, page.birthDates.length);

        for (uint256 i; i < n; ++i) {
            bytes32 playerId = page.playerIds[i];
            if (playerId == bytes32(0) || page.clubIds[i] == bytes32(0)) revert Errors.ZeroId();
            if (page.birthDates[i] == 0) revert Errors.ZeroBirthDate(playerId);

            buf.playerIds.push(playerId);
            buf.clubIds.push(page.clubIds[i]);
            buf.playerNames.push(page.playerNames[i]);
            buf.playerSymbols.push(page.playerSymbols[i]);
            buf.birthDates.push(page.birthDates[i]);
        }
    }

    // --------------------------------------------
    //  Phase 2 — SORT_TRANSIENT
    // --------------------------------------------

    /**
     * @dev Drains the complete buffer in two steps (gas-chunked): upsert/rebuild, then
     *      removals. Auto-finalizes on the last removals chunk.
     */
    function _sortTransient(SquadReport memory r) private {
        WorkflowControl storage c = _control;
        if (c.pass == PassKind.None) revert Errors.NoActivePass();
        if (r.leagueId != c.activeLeagueId || r.seasonId != c.activeSeasonId) {
            revert Errors.NotActiveSeason(r.leagueId, r.seasonId);
        }

        SeasonRun storage row = _activeSeasonRow();
        if (row.status != RunStatus.TRANSIENT) revert Errors.SeasonNotSortable(r.seasonId);

        TransientReturn storage buf = _transient;
        if (buf.seasonId != r.seasonId) revert Errors.TransientSeasonMismatch(r.seasonId, buf.seasonId);
        if (buf.nextPage != SQUAD_FETCH_PAGE_DONE) revert Errors.TransientIncomplete(r.seasonId, buf.nextPage);

        SortCursor storage cursor = _sortCursor;
        if (!cursor.active) {
            cursor.active = true;
            cursor.leagueId = r.leagueId;
            cursor.seasonId = r.seasonId;
            cursor.step = SORT_STEP_UPSERT;
            cursor.offset = 0;
        }

        if (cursor.step == SORT_STEP_UPSERT) {
            if (_sortUpsertChunk(buf, cursor)) return;
            _prepareRemovalCandidates(buf);
            cursor.step = SORT_STEP_REMOVALS;
            cursor.offset = 0;
            if (_removalCandidates.length != 0) {
                emit WorkflowEvents.SortPage(r.leagueId, r.seasonId, SORT_STEP_REMOVALS, 0);
                return;
            }
        }

        if (_sortRemovalsChunk(buf, cursor)) return;

        _finalizeSeason(row);
    }

    /**
     * @dev Upsert `SORT_CHUNK` buffer rows. Returns true if more upsert work remains.
     */
    function _sortUpsertChunk(TransientReturn storage buf, SortCursor storage cursor) private returns (bool more) {
        uint256 offset = cursor.offset;
        uint256 total = buf.playerIds.length;
        uint256 end = offset + SORT_CHUNK;
        if (end > total) end = total;

        for (uint256 i = offset; i < end; ++i) {
            _upsertPlayer(buf, i);
        }

        if (end < total) {
            // forge-lint: disable-next-line(unsafe-typecast)
            cursor.offset = uint32(end);
            // forge-lint: disable-next-line(unsafe-typecast)
            emit WorkflowEvents.SortPage(buf.leagueId, buf.seasonId, SORT_STEP_UPSERT, uint32(end));
            return true;
        }
        return false;
    }

    /**
     * @dev Upsert one buffer row into MinutesStore and append into this season's SquadList.
     *      First club touch stages the prior roster as removal candidates, then rebuilds.
     */
    function _upsertPlayer(TransientReturn storage buf, uint256 i) private {
        bytes32 playerId = buf.playerIds[i];
        bytes32 clubId = buf.clubIds[i];
        bytes32 leagueId = buf.leagueId;
        bytes32 seasonId = buf.seasonId;

        MinutesStore storage store = _minutesStore[playerId];

        if (!_tracked[playerId]) {
            _tracked[playerId] = true;
            _playerIds.push(playerId);
            store.birthDate = buf.birthDates[i];
            store.startYearCurrentLeague = buf.seasonStartYear;
            emit Events.SquadPlayerCreated(playerId, buf.birthDates[i]);
        } else if (store.birthDate == 0) {
            store.birthDate = buf.birthDates[i];
        }

        if (bytes(store.name).length == 0 && bytes(buf.playerNames[i]).length != 0) {
            store.name = buf.playerNames[i];
            store.symbol = buf.playerSymbols[i];
            emit Events.SquadPlayerMetadataSet(playerId, buf.playerNames[i], buf.playerSymbols[i]);
        }

        // Membership write — stage change buckets + emit before overwrite (transfer signal).
        bytes32 prevLeague = store.currentLeagueId;
        bytes32 prevClub = store.currentClubId;
        if (prevLeague != bytes32(0) && prevLeague != leagueId) {
            _pendingLeagueChanged.push(playerId);
            emit Events.PlayerLeagueChanged(playerId, prevLeague, leagueId);
            // New league tenure — NewTransfer / 1-min continuity for this season.
            store.startYearCurrentLeague = buf.seasonStartYear;
        }
        if (prevClub != bytes32(0) && prevClub != clubId) {
            _pendingClubChanged.push(playerId);
            emit Events.PlayerClubChanged(playerId, prevClub, clubId);
        }
        store.currentLeagueId = leagueId;
        store.currentClubId = clubId;
        // Return from leave / cross-league reappear — keep minutes, clear staleness stamp.
        if (store.deactivatedAt != 0) {
            store.deactivatedAt = 0;
        }
        _lastSeasonSeen[playerId] = seasonId;

        _ensureLeagueClub(leagueId, clubId);

        SquadList storage list = _squadLists[clubId];
        if (_clubSquadSeason[clubId] != seasonId) {
            _clubSquadSeason[clubId] = seasonId;
            _stageSquadForRemoval(list);
            delete _squadLists[clubId];
            list.clubId = clubId;
        }
        list.playerIds.push(playerId);
    }

    /**
     * @dev After upserts: clubs never stamped this season are absent from the snapshot
     *      (relegation / dissolved / unsupported). Stage their prior rosters as removal
     *      candidates, then drop the club from `_leagueClubs` / SquadList entirely —
     *      it is re-added via `_ensureLeagueClub` if it returns in a later season.
     */
    function _prepareRemovalCandidates(TransientReturn storage buf) private {
        bytes32 leagueId = buf.leagueId;
        bytes32 seasonId = buf.seasonId;
        bytes32[] storage clubs = _leagueClubs[leagueId];
        uint256 n = clubs.length;
        uint256 keep;

        for (uint256 i; i < n; ++i) {
            bytes32 clubId = clubs[i];
            if (_clubSquadSeason[clubId] == seasonId) {
                clubs[keep] = clubId;
                unchecked {
                    ++keep;
                }
                continue;
            }

            _stageSquadForRemoval(_squadLists[clubId]);
            delete _squadLists[clubId];
            delete _clubSquadSeason[clubId];
            delete _leagueClubKnown[leagueId][clubId];
        }

        while (clubs.length > keep) {
            clubs.pop();
        }
    }

    function _stageSquadForRemoval(SquadList storage list) private {
        uint256 n = list.playerIds.length;
        for (uint256 i; i < n; ++i) {
            bytes32 playerId = list.playerIds[i];
            if (_removalCandidateQueued[playerId]) continue;
            _removalCandidateQueued[playerId] = true;
            _removalCandidates.push(playerId);
        }
    }

    /**
     * @dev Process `SORT_CHUNK` removal candidates. True exit = not in season membership
     *      and still attributed to this league. Returns true if more removal work remains.
     */
    function _sortRemovalsChunk(TransientReturn storage buf, SortCursor storage cursor) private returns (bool more) {
        uint256 offset = cursor.offset;
        uint256 total = _removalCandidates.length;
        uint256 end = offset + SORT_CHUNK;
        if (end > total) end = total;

        bytes32 seasonId = buf.seasonId;
        bytes32 leagueId = buf.leagueId;

        for (uint256 i = offset; i < end; ++i) {
            bytes32 playerId = _removalCandidates[i];
            _removalCandidateQueued[playerId] = false;

            if (_lastSeasonSeen[playerId] == seasonId) continue;

            MinutesStore storage store = _minutesStore[playerId];
            // Only treat as a league exit when membership still points at this league.
            if (store.currentLeagueId != leagueId) continue;

            store.currentClubId = bytes32(0);
            // forge-lint: disable-next-line(unsafe-typecast)
            store.deactivatedAt = uint64(block.timestamp);
            _pendingLeftLeague.push(playerId);
            emit Events.PlayerLeftLeague(playerId);
        }

        if (end < total) {
            // forge-lint: disable-next-line(unsafe-typecast)
            cursor.offset = uint32(end);
            // forge-lint: disable-next-line(unsafe-typecast)
            emit WorkflowEvents.SortPage(leagueId, seasonId, SORT_STEP_REMOVALS, uint32(end));
            return true;
        }
        return false;
    }

    function _ensureLeagueClub(bytes32 leagueId, bytes32 clubId) private {
        if (_leagueClubKnown[leagueId][clubId]) return;
        _leagueClubKnown[leagueId][clubId] = true;
        _leagueClubs[leagueId].push(clubId);
    }

    /**
     * @dev Snapshot + clear staged league-leavers for the verifier's TransferLocker handoff.
     */
    function _takePendingLeftLeague() internal returns (bytes32[] memory ids) {
        uint256 n = _pendingLeftLeague.length;
        if (n == 0) return ids;
        ids = _pendingLeftLeague;
        delete _pendingLeftLeague;
    }

    /// @dev Snapshot + clear staged club movers (MinutesStore already holds the new club).
    function _takePendingClubChanged() internal returns (bytes32[] memory ids) {
        uint256 n = _pendingClubChanged.length;
        if (n == 0) return ids;
        ids = _pendingClubChanged;
        delete _pendingClubChanged;
    }

    /// @dev Snapshot + clear staged league movers (MinutesStore already holds the new league).
    function _takePendingLeagueChanged() internal returns (bytes32[] memory ids) {
        uint256 n = _pendingLeagueChanged.length;
        if (n == 0) return ids;
        ids = _pendingLeagueChanged;
        delete _pendingLeagueChanged;
    }

    /**
     * @dev Drop a tracked player from `_playerIds` / `_minutesStore` (swap-and-pop).
     *      Caller must ensure index is in range. Used by verify staleness GC.
     */
    function _purgePlayerAt(uint256 index) internal {
        bytes32 playerId = _playerIds[index];
        delete _minutesStore[playerId];
        delete _tracked[playerId];

        uint256 last = _playerIds.length - 1;
        if (index != last) {
            _playerIds[index] = _playerIds[last];
        }
        _playerIds.pop();
    }

    // --------------------------------------------
    //  Finalize + pass orchestration (onchain-automated)
    // --------------------------------------------

    /**
     * @dev Only place the buffer is cleared and `activeSeasonId` advances — guarantees
     *      no next-season FETCH until the previous season is fully upserted + removal-scanned.
     *
     *      Finalize rule (monotonic year tick):
     *        - `seasonStartYear < currentSeasonStartYear` → `ARTIFACT`
     *        - else → `IDLE`, and if `seasonStartYear > current` tick year forward
     *        - every finalize: demote any other `IDLE` with `seasonStartYear < current` → `ARTIFACT`
     */
    function _finalizeSeason(SeasonRun storage row) private {
        uint16 year = row.seasonStartYear;
        uint16 current = _control.currentSeasonStartYear;

        if (year < current) {
            row.status = RunStatus.ARTIFACT;
        } else {
            row.status = RunStatus.IDLE;
            if (year > current) {
                _control.currentSeasonStartYear = year;
            }
        }

        // Seal invariant: no historical IDLE leftovers after any finalize.
        _artifactIdleSeasonsBefore(_control.currentSeasonStartYear);

        // Emit SquadListUpdated for clubs retained this season (absent clubs already pruned).
        bytes32 leagueId = _transient.leagueId;
        bytes32[] storage clubs = _leagueClubs[leagueId];
        uint256 n = clubs.length;
        for (uint256 i; i < n; ++i) {
            bytes32 clubId = clubs[i];
            emit Events.SquadListUpdated(clubId, _squadLists[clubId].playerIds.length);
        }

        delete _transient;
        delete _sortCursor;
        delete _removalCandidates;

        _advanceAfterFinalize();
    }

    /// @dev Any IDLE season with a lower start year than `year` → ARTIFACT.
    function _artifactIdleSeasonsBefore(uint16 year) private {
        uint256 leagues = _runBook.leagueIds.length;
        for (uint256 li; li < leagues; ++li) {
            SeasonRun[] storage rows = _runBook.seasons[li];
            uint256 n = rows.length;
            for (uint256 si; si < n; ++si) {
                SeasonRun storage other = rows[si];
                if (other.status == RunStatus.IDLE && other.seasonStartYear < year) {
                    other.status = RunStatus.ARTIFACT;
                }
            }
        }
    }

    /// @dev Next work item or wind the pass down. All wakes are store-emitted events.
    function _advanceAfterFinalize() private {
        WorkflowControl storage c = _control;

        if (c.pass == PassKind.Historical) {
            SeasonRun[] storage rows = _runBook.seasons[c.activeLeagueIndex];
            uint256 next = uint256(c.activeSeasonIndex) + 1;

            if (next < rows.length) {
                // forge-lint: disable-next-line(unsafe-typecast)
                c.activeSeasonIndex = uint16(next);
                c.activeSeasonId = rows[next].seasonId;
                emit WorkflowEvents.SeasonReady(c.activeLeagueId, c.activeSeasonId);
                return;
            }

            // Informational only — next league is started below via SeasonsQueued.
            emit WorkflowEvents.PopulationComplete(c.activeLeagueId);
            ++_backfilledLeagues;
            _idleOrResume();
            return;
        }

        (bool found, uint16 li, uint16 si) = _findIdleSeason(c.activeLeagueIndex, uint256(c.activeSeasonIndex) + 1);
        if (found) {
            c.activeLeagueIndex = li;
            c.activeSeasonIndex = si;
            c.activeLeagueId = _runBook.leagueIds[li];
            c.activeSeasonId = _runBook.seasons[li][si].seasonId;
            emit WorkflowEvents.SeasonReady(c.activeLeagueId, c.activeSeasonId);
            return;
        }

        lastCurrentPassCompletedAt = uint64(block.timestamp);
        _idleOrResume();
    }

    /**
     * @dev Resume work without waiting for cron:
     *      1) Historical — next non-backfilled league → `SeasonsQueued`
     *      2) Deferred appends (`SeasonOpened` while a pass was busy) → Current + `SeasonReady`
     *      3) Else truly idle → `LoopPending` (+ `HistoricalBackfillComplete` when leaving
     *         a finished historical pass). Current-year IDLE left after historical wait for
     *         cron resweep — they were already fetched in the historical pass.
     */
    function _idleOrResume() private {
        WorkflowControl storage c = _control;
        uint256 pendingLeague = _backfilledLeagues;

        if (pendingLeague < _runBook.leagueIds.length) {
            SeasonRun[] storage rows = _runBook.seasons[pendingLeague];
            c.pass = PassKind.Historical;
            c.historicalActive = true;
            // forge-lint: disable-next-line(unsafe-typecast)
            c.activeLeagueIndex = uint16(pendingLeague);
            c.activeLeagueId = _runBook.leagueIds[pendingLeague];
            c.activeSeasonIndex = 0;
            c.activeSeasonId = rows[0].seasonId;
            // forge-lint: disable-next-line(unsafe-typecast)
            emit WorkflowEvents.SeasonsQueued(c.activeLeagueId, uint16(rows.length));
            return;
        }

        if (_wakeDeferredAppend()) return;

        bool finishedHistorical = c.pass == PassKind.Historical && _backfilledLeagues == _runBook.leagueIds.length
            && _runBook.leagueIds.length != 0;

        c.pass = PassKind.None;
        c.historicalActive = false;
        c.activeLeagueId = bytes32(0);
        c.activeLeagueIndex = 0;
        c.activeSeasonId = bytes32(0);
        c.activeSeasonIndex = 0;
        emit WorkflowEvents.LoopPending(_runBook.runNumber);

        // RoundManager wake — fixtures / matchweeks after squads historical bootstrap.
        if (finishedHistorical) {
            // forge-lint: disable-next-line(unsafe-typecast)
            emit WorkflowEvents.HistoricalBackfillComplete(_runBook.runNumber, uint16(_runBook.leagueIds.length));
        }
    }

    /**
     * @dev Pop the oldest deferred append and start a Current pass + `SeasonReady`.
     *      Skips entries that are no longer `IDLE` (already drained by an intervening pass).
     */
    function _wakeDeferredAppend() private returns (bool woken) {
        while (_deferredWakeSeasonIds.length != 0) {
            bytes32 leagueId = _deferredWakeLeagueIds[0];
            bytes32 seasonId = _deferredWakeSeasonIds[0];
            _dequeueDeferredWake();

            uint256 li = _leagueIndex(leagueId);
            SeasonRun[] storage rows = _runBook.seasons[li];
            uint256 n = rows.length;
            for (uint256 si; si < n; ++si) {
                if (rows[si].seasonId != seasonId) continue;
                if (rows[si].status != RunStatus.IDLE) break;
                _startCurrentPassAt(li, si);
                emit WorkflowEvents.SeasonReady(leagueId, seasonId);
                return true;
            }
        }
        return false;
    }

    function _dequeueDeferredWake() private {
        uint256 last = _deferredWakeSeasonIds.length - 1;
        for (uint256 i; i < last; ++i) {
            _deferredWakeLeagueIds[i] = _deferredWakeLeagueIds[i + 1];
            _deferredWakeSeasonIds[i] = _deferredWakeSeasonIds[i + 1];
        }
        _deferredWakeLeagueIds.pop();
        _deferredWakeSeasonIds.pop();
    }

    /// @dev Claim the mutex for a Current pass on a specific RunBook row + wake fetch.
    function _startCurrentPassAt(uint256 leagueIndex, uint256 seasonIndex) private {
        WorkflowControl storage c = _control;
        c.pass = PassKind.Current;
        c.historicalActive = false;
        // forge-lint: disable-next-line(unsafe-typecast)
        c.activeLeagueIndex = uint16(leagueIndex);
        // forge-lint: disable-next-line(unsafe-typecast)
        c.activeSeasonIndex = uint16(seasonIndex);
        c.activeLeagueId = _runBook.leagueIds[leagueIndex];
        c.activeSeasonId = _runBook.seasons[leagueIndex][seasonIndex].seasonId;
    }

    /// @dev Cron entry: first FETCH report while idle claims the mutex for a current pass.
    function _startCurrentPass(bytes32 leagueId, bytes32 seasonId) private {
        WorkflowControl storage c = _control;
        if (c.currentSeasonStartYear == 0) revert Errors.NoCurrentSeasonYear();

        (bool found, uint16 li, uint16 si) = _findIdleSeason(0, 0);
        if (!found) revert Errors.NoQueuedWork();

        SeasonRun storage row = _runBook.seasons[li][si];
        if (_runBook.leagueIds[li] != leagueId || row.seasonId != seasonId) {
            revert Errors.NotActiveSeason(leagueId, seasonId);
        }

        c.pass = PassKind.Current;
        c.activeLeagueIndex = li;
        c.activeLeagueId = leagueId;
        c.activeSeasonIndex = si;
        c.activeSeasonId = seasonId;
    }

    /// @dev Next `IDLE` season for `currentSeasonStartYear`. Cron / current-pass advance use this.
    function _findIdleSeason(
        uint256 startLeague,
        uint256 startSeason
    ) private view returns (bool found, uint16 leagueIndex, uint16 seasonIndex) {
        uint256 leagues = _runBook.leagueIds.length;
        uint256 si = startSeason;
        uint16 currentYear = _control.currentSeasonStartYear;

        for (uint256 li = startLeague; li < leagues; ++li) {
            SeasonRun[] storage rows = _runBook.seasons[li];
            uint256 n = rows.length;
            for (; si < n; ++si) {
                if (rows[si].status == RunStatus.IDLE && rows[si].seasonStartYear == currentYear) {
                    // forge-lint: disable-next-line(unsafe-typecast)
                    return (true, uint16(li), uint16(si));
                }
            }
            si = 0;
        }
        return (false, 0, 0);
    }

    function _activeSeasonRow() private view returns (SeasonRun storage) {
        return _runBook.seasons[_control.activeLeagueIndex][_control.activeSeasonIndex];
    }

    // --------------------------------------------
    //  Admin (internal — role-gated wrappers above)
    // --------------------------------------------

    /**
     * @dev Append a league (seasons oldest→newest) to the `RunBook`. If idle, immediately
     *      starts the historical pass (`SeasonsQueued`); otherwise waits its queue turn.
     */
    function _queueLeague(bytes32 leagueId, bytes32[] memory seasonIds, uint16[] memory seasonStartYears) internal {
        if (leagueId == bytes32(0)) revert Errors.ZeroId();
        if (_leagueQueued[leagueId]) revert Errors.LeagueAlreadyQueued(leagueId);
        if (_control.currentSeasonStartYear == 0) revert Errors.NoCurrentSeasonYear();

        uint256 n = seasonIds.length;
        if (n == 0 || n != seasonStartYears.length) revert Errors.LengthMismatch(n, seasonStartYears.length);

        _leagueQueued[leagueId] = true;
        _runBook.leagueIds.push(leagueId);
        SeasonRun[] storage rows = _runBook.seasons.push();

        uint16 prevYear;
        for (uint256 i; i < n; ++i) {
            if (seasonIds[i] == bytes32(0) || seasonStartYears[i] == 0) revert Errors.ZeroId();
            if (seasonStartYears[i] <= prevYear) revert Errors.SeasonsNotAscending();
            prevYear = seasonStartYears[i];
            rows.push(
                SeasonRun({ seasonId: seasonIds[i], seasonStartYear: seasonStartYears[i], status: RunStatus.IDLE })
            );
        }

        ++_runBook.runNumber;

        if (_control.pass == PassKind.None) {
            _idleOrResume();
        }
    }

    /**
     * @dev Append one newer season under an already-queued league (CRE registry divergence).
     *      Idle → start Current pass + `SeasonReady` immediately (no cron wait).
     *      Busy → defer wake; `_idleOrResume` emits `SeasonReady` as soon as the mutex frees.
     */
    function _appendSeason(uint256 leagueIndex, bytes32 seasonId, uint16 seasonStartYear) private {
        SeasonRun[] storage rows = _runBook.seasons[leagueIndex];
        rows.push(SeasonRun({ seasonId: seasonId, seasonStartYear: seasonStartYear, status: RunStatus.IDLE }));
        uint256 seasonIndex = rows.length - 1;
        ++_runBook.runNumber;

        bytes32 leagueId = _runBook.leagueIds[leagueIndex];
        if (_control.pass == PassKind.None) {
            _startCurrentPassAt(leagueIndex, seasonIndex);
            emit WorkflowEvents.SeasonReady(leagueId, seasonId);
        } else {
            _deferredWakeLeagueIds.push(leagueId);
            _deferredWakeSeasonIds.push(seasonId);
        }
    }

    function _leagueIndex(bytes32 leagueId) private view returns (uint256) {
        uint256 n = _runBook.leagueIds.length;
        for (uint256 i; i < n; ++i) {
            if (_runBook.leagueIds[i] == leagueId) return i;
        }
        revert Errors.LeagueNotQueued(leagueId);
    }

    function _seasonQueued(uint256 leagueIndex, bytes32 seasonId) private view returns (bool) {
        SeasonRun[] storage rows = _runBook.seasons[leagueIndex];
        uint256 n = rows.length;
        for (uint256 i; i < n; ++i) {
            if (rows[i].seasonId == seasonId) return true;
        }
        return false;
    }

    /// @dev Blocked mid-pass: finalize classification must not shift under an active pass.
    function _setCurrentSeasonStartYear(uint16 year) internal {
        if (year == 0) revert Errors.ZeroId();
        if (_control.pass != PassKind.None) revert Errors.PassActive();
        _control.currentSeasonStartYear = year;
    }

    /// @dev G-index origin; set once at proxy init (does not track season ticks).
    function _setScoreBaseYear(uint16 year) internal {
        if (year == 0) revert Errors.ZeroId();
        scoreBaseYear = year;
    }

    // --------------------------------------------
    //  Internal — AddressBook hooks
    // --------------------------------------------

    /// @dev Sole authorized `recordAppearances` caller (PpmVerifier).
    function _ppmVerifier() internal view returns (address) {
        return _getAddress(_addressKey(Addresses.PPM_VERIFIER));
    }

    /// @dev Season identity + treasuries for sync / G-index.
    function _tournamentRegistry() internal view returns (ITournamentRegistry) {
        return ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || CreReceiver.supportsInterface(interfaceId);
    }

    // --------------------------------------------
    //  Internal — position aggregate
    // --------------------------------------------

    /**
     * @dev Add `minsPlayed` to career `positionMinutes[posIndex]` and update `expectedPosition`
     *      only when this slot strictly beats the current best (ties keep the incumbent).
     */
    function _accumulatePosition(
        MinutesStore storage store,
        uint256 posIndex,
        uint32 minsPlayed
    ) private returns (uint32 cumulative) {
        cumulative = store.positionMinutes[posIndex] + minsPlayed;
        store.positionMinutes[posIndex] = cumulative;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 bestIdx = uint256(uint8(store.expectedPosition));
        if (posIndex != bestIdx && cumulative > store.positionMinutes[bestIdx]) {
            // forge-lint: disable-next-line(unsafe-typecast)
            store.expectedPosition = Position(uint8(posIndex));
        }
    }

    // --------------------------------------------
    //  Internal — rolling score / league clock
    // --------------------------------------------

    /// @dev RunBook domestic league + registry calendar match for this batch season.
    function _isScoringSeason(bytes32 leagueId, bytes32 seasonId, uint16 seasonStartYear) private view returns (bool) {
        if (!_leagueQueued[leagueId]) return false;
        try _tournamentRegistry().getSeasonId(leagueId, seasonStartYear) returns (bytes32 expected) {
            return expected != bytes32(0) && expected == seasonId;
        } catch {
            return false;
        }
    }

    function _getOrCreateLeagueMinutes(
        MinutesStore storage store,
        bytes32 leagueId
    ) private returns (LeagueMinutes storage lm) {
        uint256 n = store.leagueMinutes.length;
        for (uint256 i; i < n; ++i) {
            if (store.leagueMinutes[i].leagueId == leagueId) {
                return store.leagueMinutes[i];
            }
        }

        store.leagueMinutes.push();
        lm = store.leagueMinutes[n];
        lm.leagueId = leagueId;
    }

    /**
     * @dev Align `lm` to appearance global round `G_app`, then add minutes.
     *      Out-of-order (`G_app < last`): add decayed contribution; do not move `last`.
     */
    function _applyAppearanceScore(
        LeagueMinutes storage lm,
        bytes32 leagueId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        uint32 minsPlayed,
        FinalRoundCache memory frCache
    ) private {
        uint32 gApp = _toGlobalRound(leagueId, seasonStartYear, roundNumber, frCache);
        uint256 addWad = uint256(minsPlayed) * SCORE_WAD;
        uint32 last = lm.lastScoreGlobalRound;

        if (last == 0) {
            lm.weightedScoreWad = addWad;
            lm.lastScoreGlobalRound = gApp;
            return;
        }

        if (gApp > last) {
            lm.weightedScoreWad = _decay(lm.weightedScoreWad, gApp - last) + addWad;
            lm.lastScoreGlobalRound = gApp;
        } else if (gApp < last) {
            lm.weightedScoreWad += _decay(addWad, last - gApp);
        } else {
            lm.weightedScoreWad += addWad;
        }
    }

    /**
     * @dev Idle-decay a league score aggregate to `gNow` (write path for verify pages).
     *      No-op when never scored, zero mass, or already at/ahead of `gNow`.
     */
    function _syncLeagueScoreToNow(LeagueMinutes storage lm, uint32 gNow) internal {
        uint32 last = lm.lastScoreGlobalRound;
        if (last == 0 || lm.weightedScoreWad == 0 || gNow <= last) return;
        lm.weightedScoreWad = _decay(lm.weightedScoreWad, gNow - last);
        lm.lastScoreGlobalRound = gNow;
    }

    /// @dev Index of `leagueId` in `store.leagueMinutes`, or `type(uint256).max` if absent.
    function _leagueMinutesIndex(MinutesStore storage store, bytes32 leagueId) internal view returns (uint256) {
        uint256 n = store.leagueMinutes.length;
        for (uint256 i; i < n; ++i) {
            if (store.leagueMinutes[i].leagueId == leagueId) return i;
        }
        return type(uint256).max;
    }

    /// @dev Live domestic-league clock → global round (`PbrTreasury` cursors).
    function _globalRoundNow(bytes32 leagueId, FinalRoundCache memory frCache) internal view returns (uint32) {
        address treasury = _tournamentRegistry().getPbrTreasury(leagueId);
        if (treasury == address(0)) revert Errors.ZeroAddress();
        (uint16 season, uint32 active,) = IPbrTreasury(treasury).getCursors();
        if (season == 0 || active == 0) revert Errors.ZeroId();
        return _toGlobalRound(leagueId, season, active, frCache);
    }

    /// @dev `G(year, round) = Σ finalRound(y) for y ∈ [scoreBaseYear, year) + round`.
    function _toGlobalRound(
        bytes32 leagueId,
        uint16 year,
        uint32 round,
        FinalRoundCache memory frCache
    ) internal view returns (uint32) {
        uint16 base = scoreBaseYear;
        if (year <= base) return round;

        uint256 acc;
        for (uint16 y = base; y < year;) {
            acc += _finalRound(leagueId, y, frCache);
            unchecked {
                ++y;
            }
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(acc + uint256(round));
    }

    function _finalRound(
        bytes32 leagueId,
        uint16 year,
        FinalRoundCache memory frCache
    ) private view returns (uint32 fr) {
        uint256 n = frCache.len;
        for (uint256 i; i < n; ++i) {
            if (frCache.leagueIds[i] == leagueId && frCache.seasonYears[i] == year) {
                return frCache.finals[i];
            }
        }

        fr = _tournamentRegistry().getFinalRound(leagueId, year);
        if (fr == 0) revert Errors.ZeroId();

        if (n < _FINAL_ROUND_CACHE_CAP) {
            frCache.leagueIds[n] = leagueId;
            frCache.seasonYears[n] = year;
            frCache.finals[n] = fr;
            // forge-lint: disable-next-line(unsafe-typecast)
            frCache.len = uint8(n + 1);
        }
    }

    function _decay(uint256 scoreWad, uint32 deltaRounds) internal pure returns (uint256) {
        if (deltaRounds == 0 || scoreWad == 0) return scoreWad;

        uint256 result = scoreWad;
        uint256 base = LAMBDA_WAD;
        uint256 exp = deltaRounds;

        while (exp > 0) {
            if (exp & 1 == 1) {
                result = (result * base) / SCORE_WAD;
            }
            base = (base * base) / SCORE_WAD;
            exp >>= 1;
        }
        return result;
    }
}
