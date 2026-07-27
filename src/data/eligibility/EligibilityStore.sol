// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CreReceiver } from "@base/abstract/CreReceiver.sol";

import { EligibilityErrors as Errors } from "@errors/data/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@events/data/EligibilityEvents.sol";
import {
    MinutesStore,
    PassKind,
    RunBook,
    RunStatus,
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
 * @notice Squads-workflow state machine: full-season CRE ingest into `MinutesStore` / `SquadList`.
 * @dev One CRE workflow pushes `SquadReport`s through `CreReceiver.onReport` → `_processReport`.
 *
 *      FETCH_TRANSIENT
 *        Append one SP page-slice into the single `TransientReturn` slot. SP `_pgNm` is
 *        typically one club; CRE may **stay-on-page** and drain that club across ~5KB
 *        reports. `personsOffset` is the within-page cursor: retries that re-send an
 *        already-accepted slice revert (`FetchOffsetMismatch`) instead of duplicating.
 *        `_pgNm` advances only when the report sets `nextPage != pageFetched` (club
 *        fully drained) or `DONE`. Season flips to `TRANSIENT` only on `DONE`.
 *
 *      SORT_TRANSIENT
 *        Gas-chunked over the **complete** buffer:
 *          (1) Upsert → `MinutesStore` (club/league change detection) + rebuild each
 *              club's `SquadList` from the buffer (first touch clears prior roster and
 *              stages those players as removal candidates).
 *          (2) Removals: candidates absent from the season membership set
 *              (`_lastSeasonSeen != seasonId`) are true exits — clear club membership
 *              and stage `_pendingLeftLeague` for the verifier / TransferLocker.
 *        Last chunk auto-finalizes: `IDLE` (current year) or `ARTIFACT` (historical),
 *        buffer cleared, pointers advanced onchain.
 *
 *      Automation (no human / no centralized server / no CRE bookkeeping handler):
 *        - Next season in-league → `SeasonReady`
 *        - Next league → `PopulationComplete` (info) + `SeasonsQueued` in the same tx
 *        - Book terminal → `LoopPending`; cron starts the next current pass
 *        There is **no** CRE `onLeagueAdvance` — advance is store-owned.
 *
 *      Abstract: `EligibilityVerifier` exposes role-gated `_queueLeague` /
 *      `_setCurrentSeasonStartYear` and calls `__CreReceiver_init`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
abstract contract EligibilityStore is CreReceiver {
    // --------------------------------------------
    //  Constants
    // --------------------------------------------

    /// @dev Players upserted / removal candidates processed per SORT execution.
    uint256 internal constant SORT_CHUNK = 50;

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

    /// @dev Clubs ever observed under a league (untouched clubs → full-squad removals).
    mapping(bytes32 leagueId => bytes32[] clubIds) internal _leagueClubs;
    mapping(bytes32 leagueId => mapping(bytes32 clubId => bool)) internal _leagueClubKnown;

    /// @dev Stamp: player appeared in the season buffer during the in-flight SORT upsert.
    mapping(bytes32 playerId => bytes32 seasonId) internal _lastSeasonSeen;

    /// @dev Prior-roster players staged during SquadList rebuilds + untouched clubs.
    bytes32[] internal _removalCandidates;
    mapping(bytes32 playerId => bool) internal _removalCandidateQueued;

    /// @dev True exits after the removal pass — drained by the verifier later.
    bytes32[] internal _pendingLeftLeague;

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

    /// @notice Deployed league-leavers staged by SORT, not yet handed to TransferLocker.
    function pendingLeftLeagueCount() external view returns (uint256) {
        return _pendingLeftLeague.length;
    }

    /**
     * @notice CRE cron gate: next current-year season to fetch, if a current pass may start.
     * @dev `ready == false` while any pass is active. Pair with `lastCurrentPassCompletedAt`
     *      for the daily-resweep throttle in workflow config.
     */
    function nextCurrentSeason() external view returns (bool ready, bytes32 leagueId, bytes32 seasonId) {
        if (_control.pass != PassKind.None || _control.currentSeasonStartYear == 0) {
            return (false, bytes32(0), bytes32(0));
        }
        (bool found, uint16 li, uint16 si) = _findCurrentSeason(0, 0);
        if (!found) return (false, bytes32(0), bytes32(0));
        return (true, _runBook.leagueIds[li], _runBook.seasons[li][si].seasonId);
    }

    // --------------------------------------------
    //  Views — persistent data
    // --------------------------------------------

    function playerCount() external view returns (uint256) {
        return _playerIds.length;
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

    function getSquadList(bytes32 clubId) external view returns (SquadList memory) {
        return _squadLists[clubId];
    }

    function isTracked(bytes32 playerId) external view returns (bool) {
        return _tracked[playerId];
    }

    // --------------------------------------------
    //  CRE fulfill — phase dispatch
    // --------------------------------------------

    /// @inheritdoc CreReceiver
    function _processReport(bytes calldata, bytes calldata report) internal override {
        SquadReport memory r = abi.decode(report, (SquadReport));
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
            emit Events.SquadPlayerCreated(playerId, buf.birthDates[i]);
        } else if (store.birthDate == 0) {
            store.birthDate = buf.birthDates[i];
        }

        if (bytes(store.name).length == 0 && bytes(buf.playerNames[i]).length != 0) {
            store.name = buf.playerNames[i];
            store.symbol = buf.playerSymbols[i];
            emit Events.SquadPlayerMetadataSet(playerId, buf.playerNames[i], buf.playerSymbols[i]);
        }

        // Membership write — prior values are the transfer signal for downstream consumers.
        store.currentLeagueId = leagueId;
        store.currentClubId = clubId;
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

    /// @dev After upserts: stage full squads of league clubs never touched this season,
    ///      then clear those rosters (missing from the season snapshot ⇒ empty club).
    function _prepareRemovalCandidates(TransientReturn storage buf) private {
        bytes32[] storage clubs = _leagueClubs[buf.leagueId];
        uint256 n = clubs.length;
        for (uint256 i; i < n; ++i) {
            bytes32 clubId = clubs[i];
            if (_clubSquadSeason[clubId] == buf.seasonId) continue;
            _stageSquadForRemoval(_squadLists[clubId]);
            delete _squadLists[clubId];
            _squadLists[clubId].clubId = clubId;
            _clubSquadSeason[clubId] = buf.seasonId;
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

    // --------------------------------------------
    //  Finalize + pass orchestration (onchain-automated)
    // --------------------------------------------

    /**
     * @dev Only place the buffer is cleared and `activeSeasonId` advances — guarantees
     *      no next-season FETCH until the previous season is fully upserted + removal-scanned.
     */
    function _finalizeSeason(SeasonRun storage row) private {
        row.status = row.seasonStartYear == _control.currentSeasonStartYear ? RunStatus.IDLE : RunStatus.ARTIFACT;

        // Emit SquadListUpdated for clubs rebuilt this season (ops / indexers).
        bytes32 seasonId = _transient.seasonId;
        bytes32 leagueId = _transient.leagueId;
        bytes32[] storage clubs = _leagueClubs[leagueId];
        uint256 n = clubs.length;
        for (uint256 i; i < n; ++i) {
            bytes32 clubId = clubs[i];
            if (_clubSquadSeason[clubId] != seasonId) continue;
            emit Events.SquadListUpdated(clubId, _squadLists[clubId].playerIds.length);
        }

        delete _transient;
        delete _sortCursor;
        delete _removalCandidates;

        _advanceAfterFinalize();
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

        (bool found, uint16 li, uint16 si) = _findCurrentSeason(c.activeLeagueIndex, uint256(c.activeSeasonIndex) + 1);
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
     * @dev Start/resume historical backfill at the first non-backfilled league, else idle.
     *      Handles leagues queued while another pass held the mutex.
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

        c.pass = PassKind.None;
        c.historicalActive = false;
        c.activeLeagueId = bytes32(0);
        c.activeLeagueIndex = 0;
        c.activeSeasonId = bytes32(0);
        c.activeSeasonIndex = 0;
        emit WorkflowEvents.LoopPending(_runBook.runNumber);
    }

    /// @dev Cron entry: first FETCH report while idle claims the mutex for a current pass.
    function _startCurrentPass(bytes32 leagueId, bytes32 seasonId) private {
        WorkflowControl storage c = _control;
        if (c.currentSeasonStartYear == 0) revert Errors.NoCurrentSeasonYear();

        (bool found, uint16 li, uint16 si) = _findCurrentSeason(0, 0);
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

    function _findCurrentSeason(
        uint256 startLeague,
        uint256 startSeason
    ) private view returns (bool found, uint16 leagueIndex, uint16 seasonIndex) {
        uint16 year = _control.currentSeasonStartYear;
        uint256 leagues = _runBook.leagueIds.length;
        uint256 si = startSeason;

        for (uint256 li = startLeague; li < leagues; ++li) {
            SeasonRun[] storage rows = _runBook.seasons[li];
            uint256 n = rows.length;
            for (; si < n; ++si) {
                SeasonRun storage row = rows[si];
                if (row.seasonStartYear == year && row.status == RunStatus.IDLE) {
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
    //  Admin (internal — verifier exposes role-gated wrappers)
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

    /// @dev Blocked mid-pass: finalize classification must not shift under an active pass.
    function _setCurrentSeasonStartYear(uint16 year) internal {
        if (year == 0) revert Errors.ZeroId();
        if (_control.pass != PassKind.None) revert Errors.PassActive();
        _control.currentSeasonStartYear = year;
    }
}
