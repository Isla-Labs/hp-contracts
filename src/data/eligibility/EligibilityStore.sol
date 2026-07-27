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
 * @dev One CRE workflow pushes `SquadReport`s through `CreReceiver.onReport` → `_processReport`,
 *      which dispatches on `SquadPhase`:
 *
 *        FETCH_TRANSIENT  append one SP page slice into the single `TransientReturn` slot.
 *                         Only the active `(leagueId, seasonId)` may append, and only while its
 *                         `SeasonRun.status == IDLE`. When `nextPage == SQUAD_FETCH_PAGE_DONE`
 *                         the season flips to `TRANSIENT` and `TransientComplete` fires.
 *        SORT_TRANSIENT   gas-chunked upsert of the **complete** buffer into `MinutesStore` /
 *                         `SquadList` (`SortPage` re-emits until drained). The final chunk
 *                         auto-finalizes: status → `IDLE` (current year) or `ARTIFACT`
 *                         (historical), buffer cleared, pointers advanced.
 *        FINALIZE         manual recovery only — sort auto-finalizes, so a season is never
 *                         observed in `POPULATED` between transactions.
 *
 *      Hard sequencing guarantees (plan decisions #1/#2):
 *        - A season is never sorted partially: SORT requires `RunStatus.TRANSIENT` **and**
 *          `TransientReturn.nextPage == SQUAD_FETCH_PAGE_DONE`.
 *        - The next season can never start fetching before the previous one is upserted:
 *          `activeSeasonId` only advances inside `_finalizeSeason`, which is also the only
 *          place the buffer is cleared — and FETCH rejects any non-active season.
 *
 *      Pass orchestration (plan decisions #6/#7):
 *        - Historical: leagues in queue order, seasons oldest→newest, `PopulationComplete`
 *          per league, `SeasonsQueued` wakes the next league.
 *        - Current: started lazily by the cron-fed FETCH report when `pass == None`
 *          (`nextCurrentSeason()` is the CRE gate view); walks every `IDLE` season whose
 *          `seasonStartYear == currentSeasonStartYear`; finalize is always `IDLE`.
 *        - Mutual exclusion is structural: both passes share the one buffer slot and the one
 *          `(activeLeagueId, activeSeasonId)` pointer pair.
 *
 *      Abstract: the concrete `EligibilityVerifier` exposes role-gated wrappers around
 *      `_queueLeague` / `_setCurrentSeasonStartYear` and calls `__CreReceiver_init`.
 *
 *      Transfer-aware membership rules (soft-discontinue leavers, league moves) are the next
 *      implementation step; SORT currently rebuilds club squads and last-write-wins membership,
 *      which converges correctly because seasons process oldest→newest.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
abstract contract EligibilityStore is CreReceiver {
    // --------------------------------------------
    //  Constants
    // --------------------------------------------

    /// @dev Players upserted per SORT execution (gas paging only — plan decision #4).
    uint256 internal constant SORT_CHUNK = 50;

    // --------------------------------------------
    //  Storage — workflow
    // --------------------------------------------

    /// @dev Pass mutex + active `(league, season)` pointers.
    WorkflowControl internal _control;

    /// @dev All leagues/seasons the workflow tracks.
    RunBook internal _runBook;

    /// @dev Single full-season staging slot (plan decision #2).
    TransientReturn internal _transient;

    /// @dev Gas cursor over `_transient` during SORT.
    SortCursor internal _sortCursor;

    /// @dev Leagues fully backfilled (`PopulationComplete` count). Historical passes resume here,
    ///      so leagues queued while another pass was running are picked up automatically.
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

    /// @dev Latest sorted squad per club (rebuilt once per season sort).
    mapping(bytes32 clubId => SquadList) internal _squadLists;

    /// @dev Last `seasonId` that rebuilt a club's `SquadList` — first touch in a new season
    ///      sort clears the previous roster so chunks can append across transactions.
    mapping(bytes32 clubId => bytes32 seasonId) internal _clubSquadSeason;

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

    /// @notice All `SeasonRun` rows under `leagueIndex` (oldest → newest).
    function leagueSeasons(uint256 leagueIndex) external view returns (SeasonRun[] memory) {
        return _runBook.seasons[leagueIndex];
    }

    /// @notice Compact staging-buffer status (avoids copying the parallel arrays).
    function transientStatus()
        external
        view
        returns (bytes32 leagueId, bytes32 seasonId, uint16 pageFetched, uint16 nextPage, uint256 stagedPlayers)
    {
        TransientReturn storage buf = _transient;
        return (buf.leagueId, buf.seasonId, buf.pageFetched, buf.nextPage, buf.playerIds.length);
    }

    function sortCursor() external view returns (SortCursor memory) {
        return _sortCursor;
    }

    /**
     * @notice CRE cron gate: next current-year season to fetch, if a current pass may start.
     * @dev `ready == false` while any pass is active (mutex) or nothing matches
     *      `currentSeasonStartYear`. Pair with `lastCurrentPassCompletedAt` for the
     *      daily-resweep throttle in workflow config.
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

    /// @notice Full per-player store (includes CRE `name` / `symbol` when set).
    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory) {
        return _minutesStore[playerId];
    }

    /// @notice Latest sorted squad for `clubId` (empty if never sorted).
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
    /// @dev CRE payload is one ABI-encoded `SquadReport`; `report.data` is a page slice on
    ///      FETCH and ignored on SORT / FINALIZE.
    function _processReport(bytes calldata, bytes calldata report) internal override {
        SquadReport memory r = abi.decode(report, (SquadReport));
        if (r.leagueId == bytes32(0) || r.seasonId == bytes32(0)) revert Errors.ZeroId();

        if (r.phase == SquadPhase.FETCH_TRANSIENT) {
            _fetchTransient(r);
        } else if (r.phase == SquadPhase.SORT_TRANSIENT) {
            _sortTransient(r);
        } else {
            _finalizeTransient(r);
        }
    }

    // --------------------------------------------
    //  Phase 1 — FETCH_TRANSIENT (append page slice)
    // --------------------------------------------

    /**
     * @dev Appends one SP page slice into the season buffer. First report while `pass == None`
     *      starts a current pass (cron entry); otherwise the report must match the active
     *      `(leagueId, seasonId)` exactly — this is the "one season at a time" gate.
     */
    function _fetchTransient(SquadReport memory r) private {
        WorkflowControl storage c = _control;

        if (c.pass == PassKind.None) {
            _startCurrentPass(r.leagueId, r.seasonId);
        } else if (r.leagueId != c.activeLeagueId || r.seasonId != c.activeSeasonId) {
            revert Errors.NotActiveSeason(r.leagueId, r.seasonId);
        }

        SeasonRun storage row = _activeSeasonRow();
        // TRANSIENT / POPULATED → buffer awaiting or in sort; ARTIFACT can never refetch.
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
        // Stay-on-page (one SP page split across ~5KB reports), advance, or DONE — never rewind.
        if (!(nextPage == pageFetched || nextPage == pageFetched + 1 || nextPage == SQUAD_FETCH_PAGE_DONE)) {
            revert Errors.InvalidNextPage(pageFetched, nextPage);
        }

        TransientReturn storage buf = _transient;
        if (buf.seasonId != r.seasonId) {
            // First page of the active season. `_finalizeSeason` is the only buffer clear, so a
            // non-empty slot here means the previous season was never upserted — hard stop.
            if (buf.seasonId != bytes32(0)) revert Errors.TransientSeasonMismatch(buf.seasonId, r.seasonId);
            if (pageFetched != 1) revert Errors.FetchPageMismatch(r.seasonId, 1, pageFetched);
            buf.leagueId = r.leagueId;
            buf.seasonId = r.seasonId;
            buf.seasonStartYear = row.seasonStartYear;
        } else if (pageFetched != buf.nextPage) {
            revert Errors.FetchPageMismatch(r.seasonId, buf.nextPage, pageFetched);
        }

        _appendPage(buf, page);
        buf.pageFetched = pageFetched;
        buf.nextPage = nextPage;

        if (nextPage == SQUAD_FETCH_PAGE_DONE) {
            row.status = RunStatus.TRANSIENT;
            emit WorkflowEvents.TransientComplete(r.leagueId, r.seasonId);
        } else {
            emit WorkflowEvents.FetchContinue(r.leagueId, r.seasonId, nextPage);
        }
    }

    /// @dev Validates and appends one page slice's parallel arrays into the buffer.
    function _appendPage(TransientReturn storage buf, TransientReturn memory page) private {
        uint256 n = page.playerIds.length;
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
    //  Phase 2 — SORT_TRANSIENT (full-season upsert, gas-chunked)
    // --------------------------------------------

    /**
     * @dev Drains `SORT_CHUNK` players from the **complete** buffer into `MinutesStore` /
     *      `SquadList`. Re-emits `SortPage` while work remains; the final chunk auto-finalizes
     *      (season status, buffer clear, pointer advance) in the same transaction.
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
        // Never sort a partial season (plan decision #1). Redundant with the status gate — cheap
        // second lock on the load-bearing invariant.
        if (buf.nextPage != SQUAD_FETCH_PAGE_DONE) revert Errors.TransientIncomplete(r.seasonId, buf.nextPage);

        SortCursor storage cursor = _sortCursor;
        uint256 offset = cursor.active ? cursor.offset : 0;
        uint256 total = buf.playerIds.length;
        uint256 end = offset + SORT_CHUNK;
        if (end > total) end = total;

        for (uint256 i = offset; i < end; ++i) {
            _upsertPlayer(buf, i);
        }

        if (end < total) {
            cursor.active = true;
            cursor.leagueId = r.leagueId;
            cursor.seasonId = r.seasonId;
            // forge-lint: disable-next-line(unsafe-typecast)
            cursor.offset = uint32(end);
            // forge-lint: disable-next-line(unsafe-typecast)
            emit WorkflowEvents.SortPage(r.leagueId, r.seasonId, uint32(end));
            return;
        }

        row.status = RunStatus.POPULATED;
        _finalizeSeason(row);
    }

    /**
     * @dev Upsert one buffer row. New players get a `MinutesStore` shell (metadata + birth date);
     *      tracked players only refresh membership. Seasons sort oldest→newest, so last-write-wins
     *      on `currentLeagueId` / `currentClubId` converges to the latest real membership.
     */
    function _upsertPlayer(TransientReturn storage buf, uint256 i) private {
        bytes32 playerId = buf.playerIds[i];
        bytes32 clubId = buf.clubIds[i];

        MinutesStore storage store = _minutesStore[playerId];

        if (!_tracked[playerId]) {
            _tracked[playerId] = true;
            _playerIds.push(playerId);
            store.birthDate = buf.birthDates[i];
            emit Events.SquadPlayerCreated(playerId, buf.birthDates[i]);
        } else if (store.birthDate == 0) {
            store.birthDate = buf.birthDates[i];
        }

        // First-fill metadata only — waiting-room / governance overrides stay intact.
        if (bytes(store.name).length == 0 && bytes(buf.playerNames[i]).length != 0) {
            store.name = buf.playerNames[i];
            store.symbol = buf.playerSymbols[i];
            emit Events.SquadPlayerMetadataSet(playerId, buf.playerNames[i], buf.playerSymbols[i]);
        }

        store.currentLeagueId = buf.leagueId;
        store.currentClubId = clubId;

        // Rebuild the club roster once per season sort, then append across chunks.
        SquadList storage list = _squadLists[clubId];
        if (_clubSquadSeason[clubId] != buf.seasonId) {
            _clubSquadSeason[clubId] = buf.seasonId;
            delete _squadLists[clubId];
            list.clubId = clubId;
        }
        list.playerIds.push(playerId);
    }

    // --------------------------------------------
    //  Phase 3 — FINALIZE
    // --------------------------------------------

    /// @dev Manual recovery path only: sort auto-finalizes, so `POPULATED` never persists
    ///      between transactions under normal operation.
    function _finalizeTransient(SquadReport memory r) private {
        WorkflowControl storage c = _control;
        if (c.pass == PassKind.None) revert Errors.NoActivePass();
        if (r.leagueId != c.activeLeagueId || r.seasonId != c.activeSeasonId) {
            revert Errors.NotActiveSeason(r.leagueId, r.seasonId);
        }

        SeasonRun storage row = _activeSeasonRow();
        if (row.status != RunStatus.POPULATED) revert Errors.SeasonNotPopulated(r.seasonId);
        _finalizeSeason(row);
    }

    /**
     * @dev The only place the buffer is cleared and the active season advances — which is what
     *      guarantees "no next-season fetch until the previous season is upserted".
     *      Current-year seasons return to `IDLE` (recurring); historical ones freeze as
     *      `ARTIFACT` (plan finalize rule).
     */
    function _finalizeSeason(SeasonRun storage row) private {
        row.status = row.seasonStartYear == _control.currentSeasonStartYear ? RunStatus.IDLE : RunStatus.ARTIFACT;

        delete _transient;
        delete _sortCursor;

        _advanceAfterFinalize();
    }

    // --------------------------------------------
    //  Pass orchestration
    // --------------------------------------------

    /// @dev Moves the active pointers to the next work item, or winds the pass down.
    function _advanceAfterFinalize() private {
        WorkflowControl storage c = _control;

        if (c.pass == PassKind.Historical) {
            SeasonRun[] storage rows = _runBook.seasons[c.activeLeagueIndex];
            uint256 next = uint256(c.activeSeasonIndex) + 1;

            if (next < rows.length) {
                // forge-lint: disable-next-line(unsafe-typecast)
                c.activeSeasonIndex = uint16(next);
                c.activeSeasonId = rows[next].seasonId;
                emit WorkflowEvents.FetchContinue(c.activeLeagueId, c.activeSeasonId, 1);
                return;
            }

            emit WorkflowEvents.PopulationComplete(c.activeLeagueId);
            ++_backfilledLeagues;
            _idleOrResume();
            return;
        }

        // Current pass: next IDLE season matching `currentSeasonStartYear`, across all leagues.
        (bool found, uint16 li, uint16 si) = _findCurrentSeason(c.activeLeagueIndex, uint256(c.activeSeasonIndex) + 1);
        if (found) {
            c.activeLeagueIndex = li;
            c.activeSeasonIndex = si;
            c.activeLeagueId = _runBook.leagueIds[li];
            c.activeSeasonId = _runBook.seasons[li][si].seasonId;
            emit WorkflowEvents.FetchContinue(c.activeLeagueId, c.activeSeasonId, 1);
            return;
        }

        lastCurrentPassCompletedAt = uint64(block.timestamp);
        _idleOrResume();
    }

    /**
     * @dev Start (or resume) historical backfill at the first non-backfilled league, else go
     *      fully idle. Handles leagues queued while another pass held the mutex.
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

    /// @dev First `IDLE` season with `seasonStartYear == currentSeasonStartYear`, scanning
    ///      forward from `(startLeague, startSeason)`.
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

    /// @dev Active `SeasonRun` row for the in-flight `(leagueIndex, seasonIndex)` pointers.
    function _activeSeasonRow() private view returns (SeasonRun storage) {
        return _runBook.seasons[_control.activeLeagueIndex][_control.activeSeasonIndex];
    }

    // --------------------------------------------
    //  Admin (internal — verifier exposes role-gated wrappers)
    // --------------------------------------------

    /**
     * @dev Append a league (seasons oldest→newest, strictly ascending years) to the `RunBook`.
     *      Requires `currentSeasonStartYear` to be set so finalize can classify seasons.
     *      If the workflow is idle this immediately starts the historical pass
     *      (`SeasonsQueued`); otherwise the league waits its turn in queue order.
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

    /// @dev Set the current-season selection year. Blocked mid-pass: finalize classification
    ///      and current-season scans must not shift under an active pass.
    function _setCurrentSeasonStartYear(uint16 year) internal {
        if (year == 0) revert Errors.ZeroId();
        if (_control.pass != PassKind.None) revert Errors.PassActive();
        _control.currentSeasonStartYear = year;
    }
}
