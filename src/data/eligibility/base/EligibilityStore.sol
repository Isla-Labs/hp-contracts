// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CreReceiver } from "@base/abstract/CreReceiver.sol";

import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";
import { PlayerStatus, Position } from "@base/global/types/PlayerSetTypes.sol";

import { EligibilityErrors as Errors } from "@errors/data/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@events/data/EligibilityEvents.sol";
import {
    Appearance,
    LAMBDA_WAD,
    MinutesStore,
    POSITION_COUNT,
    SCORE_WAD,
    SquadFillReport,
    SquadList,
    SQUAD_FILL_PAGE_DONE
} from "@types/data/EligibilityTypes.sol";

/**
 * @title EligibilityStore
 * @notice Abstract squad / minutes store: CRE squad-fill intake and PPM appearance ingest.
 * @dev Extended by `EligibilityVerifier` (criteria + rate-limited scan / waiting-room handoff).
 *      Domestic-league appearances update `weightedScoreWad` incrementally; verify decays to
 *      `G_now`. Career `minsByPosition` drives `expectedPosition`. League-leavers stage in
 *      `_pendingLeftLeague` for the verifier (no Automator here).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
abstract contract EligibilityStore is CreReceiver {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    IPlayerSetRegistry public playerSetRegistry;
    ITournamentRegistry public tournamentRegistry;

    /// @dev Domestic-league `tournamentId` whose calendars count toward the rolling score.
    bytes32 public leagueId;

    /// @dev Earliest season start year used as G-index origin (e.g. 2024).
    uint16 public baseYear;

    /// @notice Sole address allowed to call `recordAppearances` (PpmVerifier).
    address public ppmVerifier;

    /// @dev Max distinct season years cached in one score update (memory).
    uint256 internal constant _FINAL_ROUND_CACHE_CAP = 16;

    /// @dev Tx-local cache: `TournamentRegistry.getFinalRound(leagueId, year)`.
    struct FinalRoundCache {
        uint16[_FINAL_ROUND_CACHE_CAP] seasonYears;
        uint32[_FINAL_ROUND_CACHE_CAP] finals;
        uint8 len;
    }

    mapping(bytes32 playerId => MinutesStore) internal _minutesStore;

    bytes32[] internal _playerIds;
    mapping(bytes32 playerId => bool) private _tracked;

    /// @dev Per-calendar cursor for squad-fill SP pagination (`seasonId` = calendar HPID).
    mapping(bytes32 seasonId => uint16 page) private _squadFillPage;

    /// @dev Timestamp when `seasonId` last transitioned to `SQUAD_FILL_PAGE_DONE`.
    mapping(bytes32 seasonId => uint256) private _lastSquadFillSweepAt;

    /// @dev Latest active squad per club (daily-active membership sync).
    mapping(bytes32 clubId => SquadList) private _squadLists;

    /// @dev Current club for a player within this league's latest membership view (`0` = none).
    mapping(bytes32 playerId => bytes32 clubId) private _playerClub;

    /// @dev Players cleared from a club during the in-progress daily-active sweep (pending DONE).
    bytes32[] private _leftDuringSweep;

    /// @dev Deployed actives with no club after a full sweep — drained by `verifyEligibility`.
    bytes32[] internal _pendingLeftLeague;

    /// @dev Domain separator for Cancun `tstore` membership marks in `_syncClubSquad`.
    bytes32 private constant _INCOMING_SQUAD_TKEY = keccak256("EligibilityStore.incomingSquadMember");

    // --------------------------------------------
    //  Views
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

    /// @notice Timestamp when `seasonId` last hit `SQUAD_FILL_PAGE_DONE` (0 if never).
    /// @dev Used by CRE for active-season daily resweep throttle.
    function getLastSquadFillSweepAt(bytes32 seasonId) external view returns (uint256) {
        return _lastSquadFillSweepAt[seasonId];
    }

    /// @notice CRE cursor: SP `_pgNm` to request next (`0` → `1`; done → `(0, true)`).
    function nextSquadFillPageToFetch(bytes32 seasonId) external view returns (uint16 pageToFetch, bool done) {
        uint16 stored = _squadFillPage[seasonId];
        if (stored == SQUAD_FILL_PAGE_DONE) {
            return (0, true);
        }
        return (stored == 0 ? 1 : stored, false);
    }

    /// @notice Latest stored active squad for `clubId` (empty if never synced).
    function getSquadList(bytes32 clubId) external view returns (SquadList memory) {
        return _squadLists[clubId];
    }

    /// @notice Current club membership for `playerId` (`0` if not on any synced squad).
    function playerClub(bytes32 playerId) external view returns (bytes32) {
        return _playerClub[playerId];
    }

    /// @notice Full per-player store (includes CRE `name` / `symbol` when set).
    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory) {
        return _minutesStore[playerId];
    }

    /// @notice Name/symbol only — avoids copying `minsByPosition` into memory (Doppler enqueue path).
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

    /// @notice `true` when `name` is non-empty.
    function hasPlayerMetadata(bytes32 playerId) external view returns (bool) {
        return bytes(_minutesStore[playerId].name).length != 0;
    }

    /// @notice Compact ids in `playerIds` that are tracked but still missing `name`.
    function playersMissingMetadata(bytes32[] calldata mdPlayerIds) external view returns (bytes32[] memory missing) {
        uint256 length = mdPlayerIds.length;
        bytes32[] memory tmp = new bytes32[](length);
        uint256 n;
        for (uint256 i; i < length; ++i) {
            bytes32 playerId = mdPlayerIds[i];
            if (!_tracked[playerId]) continue;
            if (bytes(_minutesStore[playerId].name).length != 0) continue;
            tmp[n] = playerId;
            unchecked {
                ++n;
            }
        }
        missing = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            missing[i] = tmp[i];
        }
    }

    /// @notice Deployed league-leavers staged by CRE, not yet handed to TransferLocker.
    function pendingLeftLeagueCount() external view returns (uint256) {
        return _pendingLeftLeague.length;
    }

    // --------------------------------------------
    //  Minutes ingest (PPM / DMS)
    // --------------------------------------------

    /**
     * @notice Ingest match minutes; update career position aggregates and (for domestic league) the score.
     * @dev Squad-fill must have created the `MinutesStore` already. Per-match rows are not stored.
     *      All comps update career `minsByPosition` / `expectedPosition`. Domestic-league batches
     *      incrementally update `weightedScoreWad`; `verifyEligibility` only decays to `G_now`.
     */
    function recordAppearances(bytes32 seasonId, uint16 seasonStartYear, Appearance[] calldata appearances) external {
        if (msg.sender != ppmVerifier) revert Errors.Unauthorized();
        if (seasonId == bytes32(0) || seasonStartYear == 0) revert Errors.ZeroId();

        bool scoresLeague = _isLeagueSeason(seasonId, seasonStartYear);
        FinalRoundCache memory frCache;

        uint256 length = appearances.length;
        for (uint256 i; i < length; ++i) {
            Appearance calldata appearance = appearances[i];
            if (appearance.playerId == bytes32(0) || appearance.roundNumber == 0) revert Errors.ZeroId();
            if (appearance.minsPlayed == 0) continue;
            if (!_tracked[appearance.playerId]) revert Errors.UnknownPlayer(appearance.playerId);

            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 posIndex = uint256(uint8(appearance.position));
            if (posIndex >= POSITION_COUNT) revert Errors.ZeroId();

            MinutesStore storage store = _minutesStore[appearance.playerId];
            uint32 cumulative = _accumulatePosition(store, posIndex, appearance.minsPlayed);

            if (scoresLeague) {
                _applyAppearanceScore(store, seasonStartYear, appearance.roundNumber, appearance.minsPlayed, frCache);
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
    //  CRE fulfill (squad-fill)
    // --------------------------------------------

    /// @inheritdoc CreReceiver
    /// @dev CRE payload is ABI-encoded `SquadFillReport` (flat tuple of its fields).
    function _processReport(bytes calldata, bytes calldata report) internal override {
        SquadFillReport memory r = abi.decode(report, (SquadFillReport));

        if (r.seasonId == bytes32(0) || r.seasonStartYear == 0) revert Errors.ZeroId();
        if (r.pageFetched == 0 || r.pageFetched >= SQUAD_FILL_PAGE_DONE) {
            revert Errors.InvalidSquadFillNextPage(r.pageFetched, r.nextPage);
        }
        if (r.nextPage == 0 || r.nextPage > SQUAD_FILL_PAGE_DONE) {
            revert Errors.InvalidSquadFillNextPage(r.pageFetched, r.nextPage);
        }
        // Allow stay-on-page (partial drain), advance, or DONE — not rewind / skip ahead arbitrarily.
        if (!(r.nextPage == r.pageFetched || r.nextPage == r.pageFetched + 1 || r.nextPage == SQUAD_FILL_PAGE_DONE)) {
            revert Errors.InvalidSquadFillNextPage(r.pageFetched, r.nextPage);
        }

        uint16 stored = _squadFillPage[r.seasonId];

        if (stored == SQUAD_FILL_PAGE_DONE) {
            // Active-season daily resweep: only restart from page 1.
            if (r.pageFetched != 1) revert Errors.SquadFillSeasonDone(r.seasonId);
            // Drop any stale pending leavers from a prior incomplete sweep.
            delete _leftDuringSweep;
        } else {
            uint16 expectedFetch = stored == 0 ? 1 : stored;
            if (r.pageFetched != expectedFetch) {
                revert Errors.SquadFillPageMismatch(r.seasonId, expectedFetch, r.pageFetched);
            }
        }

        uint256 length = r.playerIds.length;
        if (length != r.birthDates.length) revert Errors.LengthMismatch(length, r.birthDates.length);

        uint256 created;
        uint256 skipped;

        for (uint256 i; i < length; ++i) {
            bytes32 playerId = r.playerIds[i];
            if (playerId == bytes32(0)) revert Errors.ZeroId();

            if (_tracked[playerId]) {
                unchecked {
                    ++skipped;
                }
                continue;
            }

            uint256 birthDate = r.birthDates[i];
            if (birthDate == 0) revert Errors.ZeroBirthDate(playerId);

            MinutesStore storage store = _minutesStore[playerId];
            store.birthDate = birthDate;
            store.earliestSeasonStartYear = r.seasonStartYear;
            // `expectedPosition` defaults to Position(0); score / minsByPosition stay empty until PPM.

            _tracked[playerId] = true;
            _playerIds.push(playerId);

            unchecked {
                ++created;
            }

            emit Events.SquadPlayerCreated(playerId, birthDate);
        }

        _applyPlayerMetadata(r.metaPlayerIds, r.names, r.symbols);

        // Daily-active membership: overwrite club squad + track leavers for DONE finalize.
        if (r.clubId != bytes32(0)) {
            _syncClubSquad(r.clubId, r.squadPlayerIds);
        }

        _squadFillPage[r.seasonId] = r.nextPage;
        if (r.nextPage == SQUAD_FILL_PAGE_DONE) {
            _lastSquadFillSweepAt[r.seasonId] = block.timestamp;
            _finalizeLeagueRemovals();
        }

        emit Events.SquadFillPageUpdated(r.seasonId, stored, r.nextPage);
        emit Events.SquadPlayersCreated(r.seasonId, r.pageFetched, created, skipped);
    }

    /**
     * @dev First-fill `name` / `symbol` for tracked players. Skips empty names and rows that
     *      already have metadata (waiting-room / governance overrides stay intact).
     */
    function _applyPlayerMetadata(
        bytes32[] memory metaPlayerIds,
        string[] memory names,
        string[] memory symbols
    ) private {
        uint256 length = metaPlayerIds.length;
        if (length == 0) {
            if (names.length != 0 || symbols.length != 0) {
                revert Errors.LengthMismatch(names.length, symbols.length);
            }
            return;
        }
        if (length != names.length) revert Errors.LengthMismatch(length, names.length);
        if (length != symbols.length) revert Errors.LengthMismatch(length, symbols.length);

        for (uint256 i; i < length; ++i) {
            bytes32 playerId = metaPlayerIds[i];
            if (playerId == bytes32(0)) revert Errors.ZeroId();
            if (!_tracked[playerId]) continue;

            MinutesStore storage store = _minutesStore[playerId];
            if (bytes(store.name).length != 0) continue;
            if (bytes(names[i]).length == 0) continue;

            store.name = names[i];
            store.symbol = symbols[i];
            emit Events.SquadPlayerMetadataSet(playerId, names[i], symbols[i]);
        }
    }

    /**
     * @dev Overwrite `SquadList` for `clubId` (CRE sends status=active only).
     *      Players previously on this list and absent from `squadPlayerIds` are pending leavers
     *      until DONE (they may still appear on another club later in the sweep).
     *      Identical ordered squads skip all writes. Membership tests use transient storage
     *      so the leaver pass is O(prev + squad), not O(prev × squad).
     */
    function _syncClubSquad(bytes32 clubId, bytes32[] memory squadPlayerIds) private {
        SquadList storage prev = _squadLists[clubId];
        if (_samePlayerIds(prev.playerIds, squadPlayerIds)) return;

        uint256 squadLen = squadPlayerIds.length;
        for (uint256 i; i < squadLen; ++i) {
            bytes32 playerId = squadPlayerIds[i];
            if (playerId == bytes32(0)) revert Errors.ZeroId();
            _tstoreIncoming(playerId, true);
        }

        uint256 prevLen = prev.playerIds.length;
        for (uint256 i; i < prevLen; ++i) {
            bytes32 playerId = prev.playerIds[i];
            if (_tloadIncoming(playerId)) continue;
            if (_playerClub[playerId] != clubId) continue;
            delete _playerClub[playerId];
            _leftDuringSweep.push(playerId);
        }

        for (uint256 i; i < squadLen; ++i) {
            bytes32 playerId = squadPlayerIds[i];
            _playerClub[playerId] = clubId;
            _tstoreIncoming(playerId, false);
        }

        _squadLists[clubId] = SquadList({ clubId: clubId, playerIds: squadPlayerIds });
        emit Events.SquadListUpdated(clubId, squadLen);
    }

    /// @dev Ordered equality of stored vs incoming squad arrays (CRE-stable order → common no-op).
    function _samePlayerIds(bytes32[] storage a, bytes32[] memory b) private view returns (bool) {
        uint256 n = a.length;
        if (n != b.length) return false;
        for (uint256 i; i < n; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function _incomingTSlot(bytes32 playerId) private pure returns (bytes32) {
        return keccak256(abi.encode(playerId, _INCOMING_SQUAD_TKEY));
    }

    function _tstoreIncoming(bytes32 playerId, bool marked) private {
        bytes32 slot = _incomingTSlot(playerId);
        assembly ("memory-safe") {
            tstore(slot, marked)
        }
    }

    function _tloadIncoming(bytes32 playerId) private view returns (bool marked) {
        bytes32 slot = _incomingTSlot(playerId);
        assembly ("memory-safe") {
            marked := tload(slot)
        }
    }

    /**
     * @dev After a full membership sweep: any player who was on some `SquadList` and is now on
     *      none (`_playerClub == 0`) has left the league. Stage deployed actives for
     *      `verifyEligibility` → TransferLocker (`LeftLeague`). Intra-league transfers
     *      re-acquire `_playerClub` before DONE and are skipped.
     */
    function _finalizeLeagueRemovals() private {
        uint256 n = _leftDuringSweep.length;

        for (uint256 i; i < n; ++i) {
            bytes32 playerId = _leftDuringSweep[i];
            if (_playerClub[playerId] != bytes32(0)) continue;
            if (!playerSetRegistry.playerExists(playerId)) continue;
            if (playerSetRegistry.getPlayerSet(playerId).status == PlayerStatus.INACTIVE) continue;

            _pendingLeftLeague.push(playerId);
            emit Events.PlayerLeftLeague(playerId);
        }
        delete _leftDuringSweep;
    }

    /**
     * @dev Snapshot + clear staged league-leavers for the verifier's Automator handoff.
     *      Returns empty when nothing is pending.
     */
    function _takePendingLeftLeague() internal returns (bytes32[] memory ids) {
        uint256 n = _pendingLeftLeague.length;
        if (n == 0) return ids;

        ids = _pendingLeftLeague;
        delete _pendingLeftLeague;
    }

    // --------------------------------------------
    //  Internal — rolling score / league clock
    // --------------------------------------------

    /**
     * @dev Fold one domestic appearance into `weightedScoreWad` (normalized to `lastScoreGlobalRound`).
     *      `G_app >= last`: decay aggregate forward, then add mins at `G_app`.
     *      `G_app < last`: late/out-of-order — add mins decayed forward to `last`.
     */
    function _applyAppearanceScore(
        MinutesStore storage store,
        uint16 seasonStartYear,
        uint32 roundNumber,
        uint32 minsPlayed,
        FinalRoundCache memory frCache
    ) internal {
        uint32 gApp = _toGlobalRound(seasonStartYear, roundNumber, frCache);
        uint256 addWad = uint256(minsPlayed) * SCORE_WAD;
        uint32 last = store.lastScoreGlobalRound;

        if (last == 0) {
            store.weightedScoreWad = addWad;
            store.lastScoreGlobalRound = gApp;
            return;
        }

        if (gApp >= last) {
            store.weightedScoreWad = _decay(store.weightedScoreWad, gApp - last) + addWad;
            store.lastScoreGlobalRound = gApp;
        } else {
            store.weightedScoreWad += _decay(addWad, last - gApp);
        }
    }

    /// @dev Bring stored score from `lastScoreGlobalRound` to `gNow` (idle decay). No-op if never scored.
    function _syncScoreToNow(MinutesStore storage store, uint32 gNow) internal {
        uint32 last = store.lastScoreGlobalRound;
        if (last == 0 || store.weightedScoreWad == 0 || gNow <= last) return;
        store.weightedScoreWad = _decay(store.weightedScoreWad, gNow - last);
        store.lastScoreGlobalRound = gNow;
    }

    function _globalRoundNow(FinalRoundCache memory frCache) internal view returns (uint32) {
        address treasury = tournamentRegistry.getPbrTreasury(leagueId);
        if (treasury == address(0)) revert Errors.ZeroAddress();
        (uint16 season, uint32 active,) = IPbrTreasury(treasury).getCursors();
        if (season == 0 || active == 0) revert Errors.ZeroId();
        return _toGlobalRound(season, active, frCache);
    }

    function _currentSeasonYear() internal view returns (uint16 season) {
        address treasury = tournamentRegistry.getPbrTreasury(leagueId);
        if (treasury == address(0)) revert Errors.ZeroAddress();
        (season,,) = IPbrTreasury(treasury).getCursors();
        if (season == 0) revert Errors.ZeroId();
    }

    /// @dev `TournamentRegistry.getFinalRound`; cached in `frCache` for the call.
    function _finalRound(uint16 year, FinalRoundCache memory frCache) internal view returns (uint32 fr) {
        uint256 n = frCache.len;
        for (uint256 i; i < n; ++i) {
            if (frCache.seasonYears[i] == year) return frCache.finals[i];
        }

        fr = tournamentRegistry.getFinalRound(leagueId, year);
        if (fr == 0) revert Errors.ZeroId();

        if (n < _FINAL_ROUND_CACHE_CAP) {
            frCache.seasonYears[n] = year;
            frCache.finals[n] = fr;
            // forge-lint: disable-next-line(unsafe-typecast)
            frCache.len = uint8(n + 1);
        }
    }

    /**
     * @dev G(year, round) = Σ finalRound(y) for y ∈ [baseYear, year) + round.
     *      Uses planned `finalRound` (not live `roundCount`).
     */
    function _toGlobalRound(uint16 year, uint32 round, FinalRoundCache memory frCache) internal view returns (uint32) {
        if (year <= baseYear) return round;

        uint256 acc;
        for (uint16 y = baseYear; y < year;) {
            acc += _finalRound(y, frCache);
            unchecked {
                ++y;
            }
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(acc + uint256(round));
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

    function _isLeagueSeason(bytes32 seasonId, uint16 seasonStartYear) internal view returns (bool) {
        try tournamentRegistry.getSeasonId(leagueId, seasonStartYear) returns (bytes32 expected) {
            return expected != bytes32(0) && expected == seasonId;
        } catch {
            return false;
        }
    }

    // --------------------------------------------
    //  Internal — position aggregate
    // --------------------------------------------

    /**
     * @dev Add `minsPlayed` to career `minsByPosition[posIndex]` and update `expectedPosition`
     *      only when this slot strictly beats the current best (ties keep the incumbent).
     */
    function _accumulatePosition(
        MinutesStore storage store,
        uint256 posIndex,
        uint32 minsPlayed
    ) private returns (uint32 cumulative) {
        cumulative = store.minsByPosition[posIndex] + minsPlayed;
        store.minsByPosition[posIndex] = cumulative;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 bestIdx = uint256(uint8(store.expectedPosition));
        if (posIndex != bestIdx && cumulative > store.minsByPosition[bestIdx]) {
            // forge-lint: disable-next-line(unsafe-typecast)
            store.expectedPosition = Position(uint8(posIndex));
        }
    }
}
