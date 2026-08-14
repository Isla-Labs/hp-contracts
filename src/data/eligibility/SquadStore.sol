// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { Oracle } from "@base/abstract/Oracle.sol";
import { RateLimit } from "@base/abstract/RateLimit.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { EligibilityErrors as Errors } from "@errors/data/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@events/data/EligibilityEvents.sol";
import { IPbrHistorical } from "@interfaces/data/IPbrHistorical.sol";
import { IRoundManager } from "@interfaces/data/IRoundManager.sol";
import { ISquadStore } from "@interfaces/data/ISquadStore.sol";
import { ITournamentRegistry } from "@interfaces/registries/ITournamentRegistry.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";
import { Appearance } from "@types/data/PbrHistoricalTypes.sol";
import { RoundFetchPhase, SeasonRef } from "@types/data/RoundManagerTypes.sol";
import {
    LAMBDA_WAD,
    LeagueMinutes,
    LeagueSquadFetch,
    MinutesStore,
    POSITION_COUNT,
    SCORE_WAD,
    SeasonSquadStep,
    SORT_CHUNK,
    SORT_STEP_REMOVALS,
    SORT_STEP_UPSERT,
    SquadFetchPage,
    SquadFetchPhase,
    SquadList,
    SQUAD_FETCH_PAGE_DONE,
    TransientReturn,
    VerifySnapshot
} from "@types/data/SquadStoreTypes.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";
import { Position } from "@types/registries/PlayerSetTypes.sol";
import { AddressProvider } from "@src/AddressProvider.sol";

/**
 * @title SquadStore
 * @notice Squad ingest SoT + historical/live oracle machine (Orchestrator `openLeague` + live refresh).
 * @dev Seasons batched under `leagueId` onchain; oracle args key off `seasonId`.
 *      Per season (earliest → latest):
 *        1) `FetchPages` — paged SP squad pull into a season buffer
 *        2) `SortChunks` — onchain apply (oracle ack / gas stipend only)
 *      Names/symbols are NOT ingested here — deploy flow uses `PlayerMetadata`.
 *      `recordAppearances` also maintains per-league λ-weighted scores for verify.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract SquadStore is AddressBook, Oracle, RateLimit, ISquadStore {
    /// @dev Drop `MinutesStore` when `deactivatedAt` is at least this old (verify GC).
    uint256 private constant STALE_AFTER = 5 * 365 days;

    /// @notice Default min seconds between `refreshSquads` kicks (cron cadence).
    uint256 public constant DEFAULT_REFRESH_COOLDOWN = 1 hours;

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    mapping(bytes32 leagueId => LeagueSquadFetch) private _fetch;
    mapping(bytes32 requestId => bytes32 leagueId) private _requestLeague;

    /// @dev Per-league season staging buffer (cleared after SortChunks finalize).
    mapping(bytes32 leagueId => TransientReturn) private _buffers;

    mapping(bytes32 playerId => MinutesStore) private _minutesStore;
    mapping(bytes32 playerId => bool) private _tracked;
    bytes32[] private _playerIds;

    mapping(bytes32 clubId => SquadList) private _squadLists;
    mapping(bytes32 clubId => bytes32 seasonId) private _clubSquadSeason;
    mapping(bytes32 leagueId => bytes32[] clubIds) private _leagueClubs;
    mapping(bytes32 leagueId => mapping(bytes32 clubId => bool)) private _leagueClubKnown;

    mapping(bytes32 playerId => bytes32 seasonId) private _lastSeasonSeen;

    mapping(bytes32 leagueId => bytes32[] candidates) private _removalCandidates;
    mapping(bytes32 leagueId => mapping(bytes32 playerId => bool)) private _removalCandidateQueued;

    // TransferLocker staging (handoff later via EligibilityVerifier).
    bytes32[] private _pendingLeftLeague;
    bytes32[] private _pendingClubChanged;
    bytes32[] private _pendingLeagueChanged;

    // --------------------------------------------
    //  Access
    // --------------------------------------------

    modifier onlyOrchestrator() {
        if (msg.sender != _getAddress(_addressKey(Addresses.ORCHESTRATOR))) {
            revert Errors.Unauthorized();
        }
        _;
    }

    modifier onlyEligibilityVerifier() {
        if (msg.sender != _getAddress(_addressKey(Addresses.ELIGIBILITY_VERIFIER))) {
            revert Errors.Unauthorized();
        }
        _;
    }

    modifier onlyPbrHistorical() {
        if (msg.sender != _getAddress(_addressKey(Addresses.PBR_HISTORICAL))) {
            revert Errors.Unauthorized();
        }
        _;
    }

    modifier onlyRoundManager() {
        if (msg.sender != _getAddress(_addressKey(Addresses.ROUND_MANAGER))) {
            revert Errors.Unauthorized();
        }
        _;
    }

    // --------------------------------------------
    //  Construction
    // --------------------------------------------

    /**
     * @param addressProvider_ Canonical `AddressProvider` (`CVM_ROUTER` must already be registered).
     * @param refreshCooldown_ Min seconds between `refreshSquads` (`0` → 1 hour).
     */
    constructor(
        address addressProvider_,
        uint256 refreshCooldown_
    )
        AddressBook(addressProvider_)
        Oracle(_cvmRouter(addressProvider_))
        RateLimit(refreshCooldown_ == 0 ? DEFAULT_REFRESH_COOLDOWN : refreshCooldown_)
    {
        if (addressProvider_ == address(0)) revert Errors.ZeroAddress();
    }

    function _cvmRouter(address addressProvider_) private view returns (address router) {
        router = AddressProvider(payable(addressProvider_)).get(keccak256(bytes(Addresses.CVM_ROUTER)));
        if (router == address(0)) revert Errors.ZeroAddress();
    }

    // --------------------------------------------
    //  Bootstrap — Orchestrator
    // --------------------------------------------

    /// @inheritdoc ISquadStore
    function openLeague(
        bytes32 leagueId,
        bytes32[] calldata seasonIds,
        uint16[] calldata seasonStartYears
    ) external onlyOrchestrator returns (bytes32 requestId) {
        if (leagueId == bytes32(0)) revert Errors.ZeroId();
        uint256 length = seasonIds.length;
        if (length != seasonStartYears.length) revert Errors.ArrayLengthsMismatch();

        LeagueSquadFetch storage fetch = _fetch[leagueId];
        if (fetch.phase != SquadFetchPhase.None) revert Errors.FetchAlreadyActive(leagueId);

        if (length == 0) {
            emit Events.SquadFetchQueued(leagueId, seasonIds, seasonStartYears, SquadFetchPhase.None);
            emit Events.SquadDataRequested(leagueId, seasonIds, seasonStartYears, bytes32(0));
            return bytes32(0);
        }

        SeasonRef[] memory ordered = _sortSeasonsAscending(seasonIds, seasonStartYears);
        for (uint256 i; i < length; ++i) {
            fetch.seasons.push(ordered[i]);
        }

        fetch.phase = SquadFetchPhase.Historical;
        fetch.step = SeasonSquadStep.FetchPages;
        fetch.seasonIndex = 0;
        fetch.pageCursor = 1;
        fetch.personsOffset = 0;
        fetch.sortStep = SORT_STEP_UPSERT;
        fetch.sortCursor = 0;
        fetch.scoreBaseYear = ordered[0].seasonStartYear;

        emit Events.SquadFetchQueued(leagueId, seasonIds, seasonStartYears, SquadFetchPhase.Historical);
        emit Events.SquadFetchPhaseChanged(leagueId, SquadFetchPhase.None, SquadFetchPhase.Historical);

        requestId = _openOracleRequest(leagueId, fetch);
        emit Events.SquadDataRequested(leagueId, seasonIds, seasonStartYears, requestId);
    }

    // --------------------------------------------
    //  Appearances — PbrHistorical
    // --------------------------------------------

    /// @inheritdoc ISquadStore
    function recordAppearances(
        bytes32 seasonId,
        uint16 seasonStartYear,
        Appearance[] calldata appearances
    ) external onlyPbrHistorical {
        if (seasonId == bytes32(0) || seasonStartYear == 0) revert Errors.ZeroId();

        uint256 length = appearances.length;
        uint256 recorded;
        for (uint256 i; i < length; ++i) {
            Appearance calldata appearance = appearances[i];
            if (appearance.playerId == bytes32(0) || appearance.roundNumber == 0) revert Errors.ZeroId();
            if (appearance.minsPlayed == 0) continue;
            if (!_tracked[appearance.playerId]) continue;

            uint256 posIndex = uint256(uint8(appearance.position));
            if (posIndex >= POSITION_COUNT) revert Errors.ZeroId();

            MinutesStore storage store = _minutesStore[appearance.playerId];
            uint32 cumulative = _accumulatePosition(store, appearance.playerId, posIndex, appearance.minsPlayed);

            bytes32 leagueId = store.currentLeagueId;
            if (leagueId != bytes32(0) && _isScoringSeason(leagueId, seasonId, seasonStartYear)) {
                LeagueMinutes storage lm = _getOrCreateLeagueMinutes(store, leagueId);
                _applyAppearanceScore(lm, leagueId, seasonStartYear, appearance.roundNumber, appearance.minsPlayed);
                emit Events.WeightedScoreUpdated(appearance.playerId, leagueId, lm.weightedScoreWad);
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
            unchecked {
                ++recorded;
            }
        }

        emit Events.AppearancesRecorded(recorded);
    }

    // --------------------------------------------
    //  Recurring — permissionless (latest season)
    // --------------------------------------------

    /// @inheritdoc ISquadStore
    function refreshSquads(bytes32 leagueId) external rateLimited returns (bytes32 requestId) {
        if (leagueId == bytes32(0)) revert Errors.ZeroId();
        LeagueSquadFetch storage fetch = _fetch[leagueId];
        if (fetch.phase != SquadFetchPhase.Live) revert Errors.NotLive(leagueId);
        if (fetch.seasons.length == 0) revert Errors.ZeroId();
        if (fetch.pendingRequestId != bytes32(0)) {
            revert Errors.OracleRequestPending(fetch.pendingRequestId);
        }

        fetch.seasonIndex = uint32(fetch.seasons.length - 1);
        fetch.step = SeasonSquadStep.FetchPages;
        fetch.pageCursor = 1;
        fetch.personsOffset = 0;
        fetch.sortStep = SORT_STEP_UPSERT;
        fetch.sortCursor = 0;

        requestId = _openOracleRequest(leagueId, fetch);
        SeasonRef storage season = fetch.seasons[fetch.seasonIndex];
        emit Events.SquadRefreshQueued(leagueId, season.seasonId, season.seasonStartYear, requestId);
    }

    /// @inheritdoc ISquadStore
    function adoptSeason(bytes32 leagueId, bytes32 seasonId, uint16 seasonStartYear) external onlyRoundManager {
        if (leagueId == bytes32(0) || seasonId == bytes32(0) || seasonStartYear == 0) revert Errors.ZeroId();
        LeagueSquadFetch storage fetch = _fetch[leagueId];
        if (fetch.phase != SquadFetchPhase.Live) revert Errors.NotLive(leagueId);

        uint256 length = fetch.seasons.length;
        if (length == 0) revert Errors.ZeroId();

        SeasonRef storage latest = fetch.seasons[length - 1];
        if (seasonId == latest.seasonId) {
            fetch.seasonIndex = uint32(length - 1);
            return;
        }
        if (seasonStartYear <= latest.seasonStartYear) revert Errors.DuplicateSeasonYear(seasonStartYear);

        fetch.seasons.push(SeasonRef({ seasonId: seasonId, seasonStartYear: seasonStartYear }));
        fetch.seasonIndex = uint32(fetch.seasons.length - 1);
        emit Events.SeasonAdopted(leagueId, seasonId, seasonStartYear);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc ISquadStore
    function getFetchState(bytes32 leagueId) external view returns (LeagueSquadFetch memory) {
        return _fetch[leagueId];
    }

    /// @inheritdoc ISquadStore
    function getLatestSeason(bytes32 leagueId) external view returns (SeasonRef memory) {
        SeasonRef[] storage seasons = _fetch[leagueId].seasons;
        uint256 length = seasons.length;
        if (length == 0) revert Errors.ZeroId();
        return seasons[length - 1];
    }

    /// @inheritdoc ISquadStore
    function getFetchPhase(bytes32 leagueId) external view returns (SquadFetchPhase) {
        return _fetch[leagueId].phase;
    }

    /// @inheritdoc ISquadStore
    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory) {
        return _minutesStore[playerId];
    }

    /// @inheritdoc ISquadStore
    function getSquadList(bytes32 clubId) external view returns (SquadList memory) {
        return _squadLists[clubId];
    }

    /// @inheritdoc ISquadStore
    function playerCount() external view returns (uint256) {
        return _playerIds.length;
    }

    /// @inheritdoc ISquadStore
    function playerIdAt(uint256 index) external view returns (bytes32) {
        return _playerIds[index];
    }

    /// @inheritdoc ISquadStore
    function playerIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory out) {
        uint256 total = _playerIds.length;
        if (offset >= total || limit == 0) return out;
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        out = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = _playerIds[offset + i];
        }
    }

    /// @inheritdoc ISquadStore
    function getVerifySnapshot(bytes32 playerId) external view returns (VerifySnapshot memory) {
        return _verifySnapshot(playerId);
    }

    // --------------------------------------------
    //  Verify page — EligibilityVerifier
    // --------------------------------------------

    /// @inheritdoc ISquadStore
    function purgeIfStale(uint256 index) external onlyEligibilityVerifier returns (bool purged) {
        if (index >= _playerIds.length) return false;
        uint64 deactivatedAt = _minutesStore[_playerIds[index]].deactivatedAt;
        if (deactivatedAt == 0) return false;
        if (block.timestamp < uint256(deactivatedAt) + STALE_AFTER) return false;
        _purgePlayerAt(index);
        return true;
    }

    /// @inheritdoc ISquadStore
    function syncAndSnapshot(bytes32 playerId) external onlyEligibilityVerifier returns (VerifySnapshot memory snap) {
        _syncPlayerScore(playerId);
        return _verifySnapshot(playerId);
    }

    /// @inheritdoc ISquadStore
    function takePendingLeftLeague() external onlyEligibilityVerifier returns (bytes32[] memory ids) {
        ids = _pendingLeftLeague;
        delete _pendingLeftLeague;
    }

    /// @inheritdoc ISquadStore
    function takePendingClubChanged() external onlyEligibilityVerifier returns (bytes32[] memory ids) {
        ids = _pendingClubChanged;
        delete _pendingClubChanged;
    }

    /// @inheritdoc ISquadStore
    function takePendingLeagueChanged() external onlyEligibilityVerifier returns (bytes32[] memory ids) {
        ids = _pendingLeagueChanged;
        delete _pendingLeagueChanged;
    }

    // --------------------------------------------
    //  Oracle callback
    // --------------------------------------------

    /// @inheritdoc Oracle
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        bytes32 leagueId = _requestLeague[requestId];
        if (leagueId == bytes32(0)) revert Errors.UnknownOracleRequest(requestId);

        LeagueSquadFetch storage fetch = _fetch[leagueId];
        if (fetch.pendingRequestId != requestId) revert Errors.UnknownOracleRequest(requestId);

        delete _requestLeague[requestId];
        fetch.pendingRequestId = bytes32(0);

        if (err.length != 0) {
            emit Events.SquadOracleFailed(requestId, leagueId, err);
            return;
        }

        SeasonRef storage season = fetch.seasons[fetch.seasonIndex];

        if (fetch.step == SeasonSquadStep.FetchPages) {
            bool morePages = _applyFetchPage(leagueId, season, fetch, response);
            if (morePages) {
                _openOracleRequest(leagueId, fetch);
                return;
            }

            fetch.step = SeasonSquadStep.SortChunks;
            fetch.sortStep = SORT_STEP_UPSERT;
            fetch.sortCursor = 0;
            emit Events.SeasonSquadStepChanged(
                leagueId, season.seasonId, SeasonSquadStep.FetchPages, SeasonSquadStep.SortChunks
            );
            _openOracleRequest(leagueId, fetch);
            return;
        }

        if (fetch.step != SeasonSquadStep.SortChunks) {
            revert Errors.UnexpectedFetchStep(uint8(fetch.step));
        }

        // Sort is onchain; oracle response is an ack / gas stipend (payload ignored).
        bool moreSort = _applySortChunk(leagueId, season.seasonId, fetch);
        if (moreSort) {
            _openOracleRequest(leagueId, fetch);
            return;
        }

        _finalizeSeasonBuffer(leagueId);
        _advanceAfterSeasonComplete(leagueId, fetch);
    }

    // --------------------------------------------
    //  Internals — oracle requests
    // --------------------------------------------

    function _openOracleRequest(bytes32 leagueId, LeagueSquadFetch storage fetch) private returns (bytes32 requestId) {
        if (fetch.pendingRequestId != bytes32(0)) revert Errors.OracleRequestPending(fetch.pendingRequestId);

        SeasonRef storage season = fetch.seasons[fetch.seasonIndex];
        uint32 cursor = fetch.step == SeasonSquadStep.FetchPages ? uint32(fetch.pageCursor) : fetch.sortCursor;
        uint16 personsOffset = fetch.step == SeasonSquadStep.FetchPages ? fetch.personsOffset : 0;

        // CVM keys off seasonId (leagueId is only the onchain batch parent).
        bytes memory args = abi.encode(season.seasonId, season.seasonStartYear, fetch.step, cursor, personsOffset);

        CvmJob job = fetch.phase == SquadFetchPhase.Live ? CvmJob.SquadSync : CvmJob.HistoricalSquadSync;
        requestId = _sendOracleRequest(job, args);

        fetch.pendingRequestId = requestId;
        _requestLeague[requestId] = leagueId;

        emit Events.SquadOracleRequested(
            requestId, leagueId, season.seasonId, season.seasonStartYear, fetch.step, cursor, personsOffset
        );
    }

    function _advanceAfterSeasonComplete(bytes32 leagueId, LeagueSquadFetch storage fetch) private {
        SeasonRef storage season = fetch.seasons[fetch.seasonIndex];
        uint32 nextSeason = fetch.seasonIndex + 1;

        if (nextSeason < fetch.seasons.length) {
            emit Events.SeasonSquadStepChanged(
                leagueId, season.seasonId, SeasonSquadStep.SortChunks, SeasonSquadStep.FetchPages
            );
            fetch.seasonIndex = nextSeason;
            fetch.step = SeasonSquadStep.FetchPages;
            fetch.pageCursor = 1;
            fetch.personsOffset = 0;
            fetch.sortStep = SORT_STEP_UPSERT;
            fetch.sortCursor = 0;
            _openOracleRequest(leagueId, fetch);
            return;
        }

        // Latest season stays queued for permissionless refreshSquads.
        SquadFetchPhase previous = fetch.phase;
        fetch.phase = SquadFetchPhase.Live;
        fetch.seasonIndex = uint32(fetch.seasons.length - 1);
        fetch.step = SeasonSquadStep.FetchPages;
        fetch.pageCursor = 1;
        fetch.personsOffset = 0;
        fetch.sortStep = SORT_STEP_UPSERT;
        fetch.sortCursor = 0;
        emit Events.SquadFetchPhaseChanged(leagueId, previous, SquadFetchPhase.Live);
        _tryOpenHistoricalDms(leagueId);
    }

    /**
     * @dev Peer rendezvous: domestic leagues only reach here; wait for RoundManager Live
     *      then kick `PbrHistorical` (idempotent if RoundManager already kicked).
     */
    function _tryOpenHistoricalDms(bytes32 leagueId) private {
        if (_roundManager().getFetchPhase(leagueId) != RoundFetchPhase.Live) return;
        _pbrHistorical().openHistorical(leagueId);
    }

    // --------------------------------------------
    //  Internals — FetchPages
    // --------------------------------------------

    function _applyFetchPage(
        bytes32 leagueId,
        SeasonRef storage season,
        LeagueSquadFetch storage fetch,
        bytes memory response
    ) private returns (bool morePages) {
        SquadFetchPage memory page = abi.decode(response, (SquadFetchPage));

        uint16 pageFetched = page.pageFetched;
        uint16 nextPage = page.nextPage;
        if (pageFetched == 0 || pageFetched >= SQUAD_FETCH_PAGE_DONE) {
            revert Errors.InvalidNextPage(pageFetched, nextPage);
        }
        if (!(nextPage == pageFetched || nextPage == pageFetched + 1 || nextPage == SQUAD_FETCH_PAGE_DONE)) {
            revert Errors.InvalidNextPage(pageFetched, nextPage);
        }

        TransientReturn storage buf = _buffers[leagueId];
        if (buf.seasonId != season.seasonId) {
            if (buf.seasonId != bytes32(0)) {
                revert Errors.TransientSeasonMismatch(buf.seasonId, season.seasonId);
            }
            if (pageFetched != 1) revert Errors.FetchPageMismatch(season.seasonId, 1, pageFetched);
            if (page.personsOffset != 0) {
                revert Errors.FetchOffsetMismatch(season.seasonId, 0, page.personsOffset);
            }
            buf.leagueId = leagueId;
            buf.seasonId = season.seasonId;
            buf.seasonStartYear = season.seasonStartYear;
            buf.pageFetched = 1;
            buf.nextPage = 1;
            buf.personsOffset = 0;
        } else {
            uint16 expectedPage = buf.nextPage == buf.pageFetched ? buf.pageFetched : buf.nextPage;
            if (pageFetched != expectedPage) {
                revert Errors.FetchPageMismatch(season.seasonId, expectedPage, pageFetched);
            }
            if (page.personsOffset != buf.personsOffset) {
                revert Errors.FetchOffsetMismatch(season.seasonId, buf.personsOffset, page.personsOffset);
            }
        }

        uint256 appended = _appendPage(buf, page);
        if (nextPage == pageFetched && appended == 0) revert Errors.InvalidNextPage(pageFetched, nextPage);

        uint256 newOffset = uint256(buf.personsOffset) + appended;
        if (newOffset > type(uint16).max) revert Errors.InvalidNextPage(pageFetched, nextPage);
        buf.personsOffset = uint16(newOffset);
        buf.pageFetched = pageFetched;
        buf.nextPage = nextPage;

        if (nextPage != pageFetched) {
            buf.personsOffset = 0;
        }

        // Mirror cursor into fetch for the next oracle args.
        if (nextPage == SQUAD_FETCH_PAGE_DONE) {
            fetch.pageCursor = pageFetched;
            fetch.personsOffset = 0;
            return false;
        }

        fetch.pageCursor = nextPage;
        fetch.personsOffset = buf.personsOffset;
        return true;
    }

    function _appendPage(TransientReturn storage buf, SquadFetchPage memory page) private returns (uint256 n) {
        n = page.playerIds.length;
        if (page.clubIds.length != n) revert Errors.LengthMismatch(n, page.clubIds.length);
        if (page.birthDates.length != n) revert Errors.LengthMismatch(n, page.birthDates.length);

        for (uint256 i; i < n; ++i) {
            bytes32 playerId = page.playerIds[i];
            if (playerId == bytes32(0) || page.clubIds[i] == bytes32(0)) revert Errors.ZeroId();
            if (page.birthDates[i] == 0) revert Errors.ZeroBirthDate(playerId);

            buf.playerIds.push(playerId);
            buf.clubIds.push(page.clubIds[i]);
            buf.birthDates.push(page.birthDates[i]);
        }
    }

    // --------------------------------------------
    //  Internals — SortChunks (onchain)
    // --------------------------------------------

    function _applySortChunk(
        bytes32 leagueId,
        bytes32 seasonId,
        LeagueSquadFetch storage fetch
    ) private returns (bool moreChunks) {
        TransientReturn storage buf = _buffers[leagueId];
        if (buf.seasonId != seasonId) revert Errors.TransientSeasonMismatch(seasonId, buf.seasonId);
        if (buf.nextPage != SQUAD_FETCH_PAGE_DONE) revert Errors.TransientIncomplete(seasonId, buf.nextPage);

        if (fetch.sortStep == SORT_STEP_UPSERT) {
            if (_sortUpsertChunk(buf, fetch)) return true;
            _prepareRemovalCandidates(leagueId, buf);
            fetch.sortStep = SORT_STEP_REMOVALS;
            fetch.sortCursor = 0;
            if (_removalCandidates[leagueId].length != 0) return true;
        }

        return _sortRemovalsChunk(leagueId, buf, fetch);
    }

    function _sortUpsertChunk(TransientReturn storage buf, LeagueSquadFetch storage fetch) private returns (bool more) {
        uint256 offset = fetch.sortCursor;
        uint256 total = buf.playerIds.length;
        uint256 end = offset + SORT_CHUNK;
        if (end > total) end = total;

        for (uint256 i = offset; i < end; ++i) {
            _upsertPlayer(buf, i);
        }

        if (end < total) {
            fetch.sortCursor = uint32(end);
            return true;
        }
        return false;
    }

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

        bytes32 prevLeague = store.currentLeagueId;
        bytes32 prevClub = store.currentClubId;
        if (prevLeague != bytes32(0) && prevLeague != leagueId) {
            _pendingLeagueChanged.push(playerId);
            emit Events.PlayerLeagueChanged(playerId, prevLeague, leagueId);
            store.startYearCurrentLeague = buf.seasonStartYear;
        }
        if (prevClub != bytes32(0) && prevClub != clubId) {
            _pendingClubChanged.push(playerId);
            emit Events.PlayerClubChanged(playerId, prevClub, clubId);
        }
        store.currentLeagueId = leagueId;
        store.currentClubId = clubId;
        if (store.deactivatedAt != 0) {
            store.deactivatedAt = 0;
        }
        _lastSeasonSeen[playerId] = seasonId;

        _ensureLeagueClub(leagueId, clubId);

        SquadList storage list = _squadLists[clubId];
        if (_clubSquadSeason[clubId] != seasonId) {
            _clubSquadSeason[clubId] = seasonId;
            _stageSquadForRemoval(leagueId, list);
            delete _squadLists[clubId];
            list.clubId = clubId;
        }
        list.playerIds.push(playerId);
    }

    function _prepareRemovalCandidates(bytes32 leagueId, TransientReturn storage buf) private {
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

            _stageSquadForRemoval(leagueId, _squadLists[clubId]);
            delete _squadLists[clubId];
            delete _clubSquadSeason[clubId];
            delete _leagueClubKnown[leagueId][clubId];
        }

        while (clubs.length > keep) {
            clubs.pop();
        }
    }

    function _stageSquadForRemoval(bytes32 leagueId, SquadList storage list) private {
        uint256 n = list.playerIds.length;
        for (uint256 i; i < n; ++i) {
            bytes32 playerId = list.playerIds[i];
            if (_removalCandidateQueued[leagueId][playerId]) continue;
            _removalCandidateQueued[leagueId][playerId] = true;
            _removalCandidates[leagueId].push(playerId);
        }
    }

    function _sortRemovalsChunk(
        bytes32 leagueId,
        TransientReturn storage buf,
        LeagueSquadFetch storage fetch
    ) private returns (bool more) {
        bytes32[] storage candidates = _removalCandidates[leagueId];
        uint256 offset = fetch.sortCursor;
        uint256 total = candidates.length;
        uint256 end = offset + SORT_CHUNK;
        if (end > total) end = total;

        bytes32 seasonId = buf.seasonId;

        for (uint256 i = offset; i < end; ++i) {
            bytes32 playerId = candidates[i];
            _removalCandidateQueued[leagueId][playerId] = false;

            if (_lastSeasonSeen[playerId] == seasonId) continue;

            MinutesStore storage store = _minutesStore[playerId];
            if (store.currentLeagueId != leagueId) continue;

            store.currentClubId = bytes32(0);
            store.deactivatedAt = uint64(block.timestamp);
            _pendingLeftLeague.push(playerId);
            emit Events.PlayerLeftLeague(playerId);
        }

        if (end < total) {
            fetch.sortCursor = uint32(end);
            return true;
        }
        return false;
    }

    function _ensureLeagueClub(bytes32 leagueId, bytes32 clubId) private {
        if (_leagueClubKnown[leagueId][clubId]) return;
        _leagueClubKnown[leagueId][clubId] = true;
        _leagueClubs[leagueId].push(clubId);
    }

    function _finalizeSeasonBuffer(bytes32 leagueId) private {
        bytes32[] storage clubs = _leagueClubs[leagueId];
        uint256 n = clubs.length;
        for (uint256 i; i < n; ++i) {
            bytes32 clubId = clubs[i];
            emit Events.SquadListUpdated(clubId, _squadLists[clubId].playerIds.length);
        }

        delete _buffers[leagueId];
        delete _removalCandidates[leagueId];
    }

    // --------------------------------------------
    //  Internals — helpers
    // --------------------------------------------

    /**
     * @dev Add `minsPlayed` to career `positionMinutes[posIndex]` and update `expectedPosition`
     *      only when this slot strictly beats the current best (ties keep the incumbent).
     */
    function _accumulatePosition(
        MinutesStore storage store,
        bytes32 playerId,
        uint256 posIndex,
        uint32 minsPlayed
    ) private returns (uint32 cumulative) {
        cumulative = store.positionMinutes[posIndex] + minsPlayed;
        store.positionMinutes[posIndex] = cumulative;

        uint256 bestIdx = uint256(uint8(store.expectedPosition));
        if (posIndex != bestIdx && cumulative > store.positionMinutes[bestIdx]) {
            Position previous = store.expectedPosition;
            Position next = Position(uint8(posIndex));
            store.expectedPosition = next;
            emit Events.PlayerExpectedPositionChanged(playerId, previous, next);
        }
    }

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

    function _syncPlayerScore(bytes32 playerId) private {
        MinutesStore storage store = _minutesStore[playerId];
        bytes32 leagueId = store.currentLeagueId;
        if (leagueId == bytes32(0)) return;

        uint256 lmIndex = _leagueMinutesIndex(store, leagueId);
        if (lmIndex == type(uint256).max) return;

        LeagueMinutes storage lm = store.leagueMinutes[lmIndex];
        if (lm.lastScoreGlobalRound == 0 || lm.weightedScoreWad == 0) return;

        address treasury = _tournamentRegistry().getPbrTreasury(leagueId);
        if (treasury == address(0)) return;
        (uint16 season, uint32 active,) = IPbrTreasury(treasury).getCursors();
        if (season == 0 || active == 0) return;

        uint32 gNow = _toGlobalRound(leagueId, season, active);
        if (gNow <= lm.lastScoreGlobalRound) return;
        lm.weightedScoreWad = _decay(lm.weightedScoreWad, gNow - lm.lastScoreGlobalRound);
        lm.lastScoreGlobalRound = gNow;
    }

    function _isScoringSeason(bytes32 leagueId, bytes32 seasonId, uint16 seasonStartYear) private view returns (bool) {
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
            if (store.leagueMinutes[i].leagueId == leagueId) return store.leagueMinutes[i];
        }
        store.leagueMinutes.push();
        lm = store.leagueMinutes[n];
        lm.leagueId = leagueId;
    }

    function _leagueMinutesIndex(MinutesStore storage store, bytes32 leagueId) private view returns (uint256) {
        uint256 n = store.leagueMinutes.length;
        for (uint256 i; i < n; ++i) {
            if (store.leagueMinutes[i].leagueId == leagueId) return i;
        }
        return type(uint256).max;
    }

    function _applyAppearanceScore(
        LeagueMinutes storage lm,
        bytes32 leagueId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        uint32 minsPlayed
    ) private {
        uint32 gApp = _toGlobalRound(leagueId, seasonStartYear, roundNumber);
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

    function _toGlobalRound(bytes32 leagueId, uint16 year, uint32 round) private view returns (uint32) {
        uint16 base = _fetch[leagueId].scoreBaseYear;
        if (base == 0 || year <= base) return round;

        uint256 acc;
        for (uint16 y = base; y < year;) {
            uint32 fr = _tournamentRegistry().getFinalRound(leagueId, y);
            if (fr == 0) revert Errors.ZeroId();
            acc += fr;
            unchecked {
                ++y;
            }
        }
        return uint32(acc + uint256(round));
    }

    function _decay(uint256 scoreWad, uint32 deltaRounds) private pure returns (uint256) {
        if (deltaRounds == 0 || scoreWad == 0) return scoreWad;
        uint256 result = scoreWad;
        uint256 base = LAMBDA_WAD;
        uint256 exp = deltaRounds;
        while (exp > 0) {
            if (exp & 1 == 1) result = (result * base) / SCORE_WAD;
            base = (base * base) / SCORE_WAD;
            exp >>= 1;
        }
        return result;
    }

    function _purgePlayerAt(uint256 index) private {
        bytes32 playerId = _playerIds[index];
        delete _minutesStore[playerId];
        delete _tracked[playerId];
        delete _lastSeasonSeen[playerId];

        uint256 last = _playerIds.length - 1;
        if (index != last) {
            _playerIds[index] = _playerIds[last];
        }
        _playerIds.pop();
    }

    function _roundManager() private view returns (IRoundManager) {
        return IRoundManager(_getAddress(_addressKey(Addresses.ROUND_MANAGER)));
    }

    function _pbrHistorical() private view returns (IPbrHistorical) {
        return IPbrHistorical(_getAddress(_addressKey(Addresses.PBR_HISTORICAL)));
    }

    function _tournamentRegistry() private view returns (ITournamentRegistry) {
        return ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }

    /// @dev Insertion sort by `seasonStartYear` ascending; reverts on duplicate years.
    function _sortSeasonsAscending(
        bytes32[] calldata seasonIds,
        uint16[] calldata seasonStartYears
    ) private pure returns (SeasonRef[] memory ordered) {
        uint256 length = seasonIds.length;
        ordered = new SeasonRef[](length);
        for (uint256 i; i < length; ++i) {
            if (seasonIds[i] == bytes32(0) || seasonStartYears[i] == 0) revert Errors.ZeroId();
            ordered[i] = SeasonRef({ seasonId: seasonIds[i], seasonStartYear: seasonStartYears[i] });
        }

        for (uint256 i = 1; i < length; ++i) {
            SeasonRef memory key = ordered[i];
            uint256 j = i;
            while (j > 0 && ordered[j - 1].seasonStartYear > key.seasonStartYear) {
                ordered[j] = ordered[j - 1];
                unchecked {
                    --j;
                }
            }
            if (j > 0 && ordered[j - 1].seasonStartYear == key.seasonStartYear) {
                revert Errors.DuplicateSeasonYear(key.seasonStartYear);
            }
            ordered[j] = key;
        }

        for (uint256 i = 1; i < length; ++i) {
            if (ordered[i].seasonStartYear == ordered[i - 1].seasonStartYear) {
                revert Errors.DuplicateSeasonYear(ordered[i].seasonStartYear);
            }
        }
    }
}
