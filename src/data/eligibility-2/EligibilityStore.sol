// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Oracle } from "@base/abstract/Oracle.sol";
import { RateLimit } from "@base/abstract/RateLimit.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";

import {
    SquadsCallback,
    SquadsRequest,
    SyncCursor,
    SyncKind
} from "./base/types/EligibilityTypes.sol";

/**
 * @title EligibilityStore
 * @notice CVM-driven squad ingest: `fetchSquadsLatest` / `fetchSquadsHistorical` → `_fulfillRequest`.
 * @dev One club per fulfill (5M callback gas). Partial club pages are accepted and
 *      auto-chained via `playerOffset` until the club (then season) is complete.
 *
 *      - `fetchSquadsLatest` — hourly rate-limited current-season kickoff (`CvmJob.SquadSync`)
 *      - `fetchSquadsHistorical` — registration / backfill kickoff (`CvmJob.HistoricalSquadSync`)
 *
 *      Upsert into `MinutesStore` / removal pass lands in a follow-up; this scaffold
 *      validates pagination, stages club pages, and advances the cursor.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract EligibilityStore is Oracle, RateLimit {
    // --------------------------------------------
    //  Constants
    // --------------------------------------------

    /// @notice Default cooldown for `fetchSquadsLatest`.
    uint256 public constant DEFAULT_LATEST_COOLDOWN = 1 hours;

    // --------------------------------------------
    //  Errors
    // --------------------------------------------

    error ZeroId();
    error SyncInFlight(bytes32 pendingRequestId);
    error NoActiveSync();
    error UnexpectedRequestId(bytes32 expected, bytes32 received);
    error SyncKindMismatch(SyncKind expected, SyncKind received);
    error SeasonMismatch(bytes32 expectedLeague, bytes32 expectedSeason, bytes32 gotLeague, bytes32 gotSeason);
    error ClubIndexMismatch(uint16 expected, uint16 received);
    error PlayerOffsetMismatch(uint16 expected, uint16 received);
    error ClubCountMismatch(uint16 expected, uint16 received);
    error InvalidClubCount();
    error LengthMismatch(uint256 playerIdsLength, uint256 birthDatesLength);
    error PlayerPageOverflow(uint16 playerOffset, uint256 pageLen, uint16 playerTotal);
    error ZeroBirthDate(bytes32 playerId);
    error ZeroClubId();

    // --------------------------------------------
    //  Events
    // --------------------------------------------

    event SquadsSyncStarted(
        SyncKind indexed kind, bytes32 indexed leagueId, bytes32 indexed seasonId, bytes32 requestId
    );
    event SquadsPageReceived(
        bytes32 indexed leagueId,
        bytes32 indexed seasonId,
        bytes32 clubId,
        uint16 clubIndex,
        uint16 playerOffset,
        uint16 pageLen,
        uint16 playerTotal
    );
    event ClubSquadComplete(bytes32 indexed leagueId, bytes32 indexed seasonId, bytes32 clubId, uint16 clubIndex);
    event SeasonSquadsComplete(SyncKind indexed kind, bytes32 indexed leagueId, bytes32 indexed seasonId);
    event SquadsSyncFailed(SyncKind indexed kind, bytes32 indexed leagueId, bytes32 indexed seasonId, bytes err);

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    SyncCursor internal _sync;

    /// @dev Clubs touched during the active season sync (staging; cleared on complete).
    bytes32[] internal _stagingClubIds;
    mapping(bytes32 clubId => bool) internal _stagingClubKnown;
    mapping(bytes32 clubId => bytes32[]) internal _stagingPlayerIds;
    mapping(bytes32 clubId => uint32[]) internal _stagingBirthDates;

    // --------------------------------------------
    //  Construction
    // --------------------------------------------

    /**
     * @param router_ Live `CvmRouter` proxy.
     * @param latestCooldown_ Min seconds between `fetchSquadsLatest` calls.
     */
    constructor(address router_, uint256 latestCooldown_) Oracle(router_) RateLimit(latestCooldown_) { }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function syncCursor() external view returns (SyncCursor memory) {
        return _sync;
    }

    function stagingClubCount() external view returns (uint256) {
        return _stagingClubIds.length;
    }

    function stagingClubAt(uint256 index) external view returns (bytes32) {
        return _stagingClubIds[index];
    }

    function stagingPlayers(bytes32 clubId) external view returns (bytes32[] memory, uint32[] memory) {
        return (_stagingPlayerIds[clubId], _stagingBirthDates[clubId]);
    }

    // --------------------------------------------
    //  Kickoffs
    // --------------------------------------------

    /**
     * @notice Start / resume a current-season squad sync (`CvmJob.SquadSync`).
     * @dev Hourly rate limit. Reverts if another sync still has a pending request
     *      or an unfinished cursor (call only when idle, or after season complete).
     */
    function fetchSquadsLatest(bytes32 leagueId, bytes32 seasonId) external rateLimited returns (bytes32 requestId) {
        return _startSync(SyncKind.Latest, leagueId, seasonId);
    }

    /**
     * @notice Start a historical season squad sync (`CvmJob.HistoricalSquadSync`).
     * @dev Intended for tournament registration. Not rate-limited; shares the sync mutex
     *      with `fetchSquadsLatest`. External for bootstrap / registry callers.
     */
    function fetchSquadsHistorical(bytes32 leagueId, bytes32 seasonId) external returns (bytes32 requestId) {
        return _startSync(SyncKind.Historical, leagueId, seasonId);
    }

    // --------------------------------------------
    //  Oracle callback
    // --------------------------------------------

    /// @inheritdoc Oracle
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        SyncCursor storage c = _sync;
        if (c.kind == SyncKind.None) revert NoActiveSync();
        if (c.pendingRequestId != requestId) revert UnexpectedRequestId(c.pendingRequestId, requestId);

        // Clear in-flight before branching so a failed decode cannot wedge the mutex forever.
        c.pendingRequestId = bytes32(0);

        if (err.length != 0) {
            emit SquadsSyncFailed(c.kind, c.leagueId, c.seasonId, err);
            _clearSync();
            return;
        }

        SquadsCallback memory page = abi.decode(response, (SquadsCallback));
        _validatePage(c, page);
        _ingestPage(page);

        bool clubDone = uint256(page.playerOffset) + page.playerIds.length >= uint256(page.playerTotal);
        if (clubDone) {
            emit ClubSquadComplete(page.leagueId, page.seasonId, page.clubId, page.clubIndex);
            // Hook for MinutesStore upsert / SquadList rebuild (follow-up).
            _onClubComplete(page);
        }

        if (!clubDone) {
            // More players in this club.
            c.expectPlayerOffset = uint16(uint256(page.playerOffset) + page.playerIds.length);
            _requestNext(c);
            return;
        }

        if (uint256(page.clubIndex) + 1 < uint256(c.clubCount)) {
            // Next club.
            c.expectClubIndex = page.clubIndex + 1;
            c.expectPlayerOffset = 0;
            _requestNext(c);
            return;
        }

        // Season complete.
        SyncKind kind = c.kind;
        bytes32 leagueId = c.leagueId;
        bytes32 seasonId = c.seasonId;
        _onSeasonComplete(kind, leagueId, seasonId);
        emit SeasonSquadsComplete(kind, leagueId, seasonId);
        _clearSync();
    }

    // --------------------------------------------
    //  Internal — request / cursor
    // --------------------------------------------

    function _startSync(SyncKind kind, bytes32 leagueId, bytes32 seasonId) private returns (bytes32 requestId) {
        if (leagueId == bytes32(0) || seasonId == bytes32(0)) revert ZeroId();

        SyncCursor storage c = _sync;
        if (c.pendingRequestId != bytes32(0)) revert SyncInFlight(c.pendingRequestId);
        if (c.kind != SyncKind.None) revert SyncInFlight(c.pendingRequestId);

        _clearStaging();

        c.kind = kind;
        c.leagueId = leagueId;
        c.seasonId = seasonId;
        c.expectClubIndex = 0;
        c.expectPlayerOffset = 0;
        c.clubCount = 0;

        requestId = _openRequest(kind, leagueId, seasonId, 0, 0);
        c.pendingRequestId = requestId;
        emit SquadsSyncStarted(kind, leagueId, seasonId, requestId);
    }

    function _requestNext(SyncCursor storage c) private {
        bytes32 requestId =
            _openRequest(c.kind, c.leagueId, c.seasonId, c.expectClubIndex, c.expectPlayerOffset);
        c.pendingRequestId = requestId;
        lastRequestId = requestId;
    }

    function _openRequest(
        SyncKind kind,
        bytes32 leagueId,
        bytes32 seasonId,
        uint16 clubIndex,
        uint16 playerOffset
    ) private returns (bytes32 requestId) {
        bytes memory args = abi.encode(
            SquadsRequest({
                leagueId: leagueId, seasonId: seasonId, clubIndex: clubIndex, playerOffset: playerOffset
            })
        );

        if (kind == SyncKind.Latest) {
            requestId = _sendOracleRequest(CvmJob.SquadSync, args);
        } else if (kind == SyncKind.Historical) {
            requestId = _sendOracleRequest(CvmJob.HistoricalSquadSync, args);
        } else {
            revert NoActiveSync();
        }
    }

    function _validatePage(SyncCursor storage c, SquadsCallback memory page) private view {
        if (page.leagueId != c.leagueId || page.seasonId != c.seasonId) {
            revert SeasonMismatch(c.leagueId, c.seasonId, page.leagueId, page.seasonId);
        }
        if (page.clubId == bytes32(0)) revert ZeroClubId();
        if (page.clubCount == 0) revert InvalidClubCount();
        if (c.clubCount != 0 && page.clubCount != c.clubCount) {
            revert ClubCountMismatch(c.clubCount, page.clubCount);
        }
        if (page.clubIndex != c.expectClubIndex) {
            revert ClubIndexMismatch(c.expectClubIndex, page.clubIndex);
        }
        if (page.playerOffset != c.expectPlayerOffset) {
            revert PlayerOffsetMismatch(c.expectPlayerOffset, page.playerOffset);
        }
        if (page.playerIds.length != page.birthDates.length) {
            revert LengthMismatch(page.playerIds.length, page.birthDates.length);
        }
        if (uint256(page.playerOffset) + page.playerIds.length > uint256(page.playerTotal)) {
            revert PlayerPageOverflow(page.playerOffset, page.playerIds.length, page.playerTotal);
        }
        // Empty club (playerTotal == 0) must send an empty page at offset 0.
        if (page.playerTotal == 0 && (page.playerOffset != 0 || page.playerIds.length != 0)) {
            revert PlayerPageOverflow(page.playerOffset, page.playerIds.length, page.playerTotal);
        }
    }

    function _ingestPage(SquadsCallback memory page) private {
        SyncCursor storage c = _sync;
        if (c.clubCount == 0) {
            c.clubCount = page.clubCount;
        }

        if (!_stagingClubKnown[page.clubId]) {
            _stagingClubKnown[page.clubId] = true;
            _stagingClubIds.push(page.clubId);
        }

        bytes32[] storage ids = _stagingPlayerIds[page.clubId];
        uint32[] storage births = _stagingBirthDates[page.clubId];

        uint256 n = page.playerIds.length;
        for (uint256 i; i < n; ++i) {
            bytes32 playerId = page.playerIds[i];
            if (playerId == bytes32(0)) revert ZeroId();
            if (page.birthDates[i] == 0) revert ZeroBirthDate(playerId);
            ids.push(playerId);
            births.push(page.birthDates[i]);
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        emit SquadsPageReceived(
            page.leagueId,
            page.seasonId,
            page.clubId,
            page.clubIndex,
            page.playerOffset,
            uint16(n),
            page.playerTotal
        );
    }

    function _onClubComplete(SquadsCallback memory page) internal virtual {
        // Reserved: stream-upsert MinutesStore + rebuild SquadList for `page.clubId`.
        page;
    }

    function _onSeasonComplete(SyncKind kind, bytes32 leagueId, bytes32 seasonId) internal virtual {
        // Reserved: removal pass + finalize. Staging cleared by `_clearSync`.
        kind;
        leagueId;
        seasonId;
    }

    function _clearSync() private {
        delete _sync;
        _clearStaging();
    }

    function _clearStaging() private {
        uint256 n = _stagingClubIds.length;
        for (uint256 i; i < n; ++i) {
            bytes32 clubId = _stagingClubIds[i];
            delete _stagingPlayerIds[clubId];
            delete _stagingBirthDates[clubId];
            delete _stagingClubKnown[clubId];
        }
        delete _stagingClubIds;
    }
}
