// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CreReceiver } from "@base/abstract/CreReceiver.sol";

import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { PlayerStatus, Position } from "@base/global/types/PlayerSetTypes.sol";

import { EligibilityErrors as Errors } from "@errors/data/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@events/data/EligibilityEvents.sol";
import {
    Appearance,
    MinutesStore,
    POSITION_COUNT,
    SeasonMinutes,
    SquadFillReport,
    SquadList,
    SQUAD_FILL_PAGE_DONE
} from "@types/data/EligibilityTypes.sol";

/**
 * @title EligibilityStore
 * @notice Abstract squad / minutes store: CRE squad-fill intake and PPM appearance ingest.
 * @dev Extended by `EligibilityVerifier` (criteria + rate-limited scan / waiting-room handoff).
 *      League-leavers are staged in `_pendingLeftLeague` for the verifier to enqueue — the store
 *      does not call Automator. Deploy the concrete verifier behind `TransparentUpgradeableProxy`.
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

    /// @notice Accumulate appearance minutes into an existing player's `SeasonMinutes` row.
    /// @dev Squad-fill must have created the `MinutesStore` already. No DOB enqueue.
    ///      One batch = one calendar (`seasonId` / `seasonStartYear`); each row carries its `roundNumber`.
    ///      Does not update `weightedScoreWad` — that happens in `verifyEligibility`.
    function recordAppearances(bytes32 seasonId, uint16 seasonStartYear, Appearance[] calldata appearances) external {
        if (msg.sender != ppmVerifier) revert Errors.Unauthorized();
        if (seasonId == bytes32(0) || seasonStartYear == 0) revert Errors.ZeroId();

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
            SeasonMinutes storage season = _getOrCreateSeasonMinutes(store, seasonId, seasonStartYear);

            uint32 cumulative = season.minsByPosition[posIndex] + appearance.minsPlayed;
            season.minsByPosition[posIndex] = cumulative;
            season.totalMinutes += appearance.minsPlayed;
            season.appearances.push(appearance);
            store.expectedPosition = _deriveExpectedPosition(store);

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
            // `expectedPosition` defaults to Position(0); score / seasonMinutes stay empty until PPM.

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
     */
    function _syncClubSquad(bytes32 clubId, bytes32[] memory squadPlayerIds) private {
        SquadList storage prev = _squadLists[clubId];
        uint256 prevLen = prev.playerIds.length;

        for (uint256 i; i < prevLen; ++i) {
            bytes32 playerId = prev.playerIds[i];
            if (_contains(squadPlayerIds, playerId)) continue;
            if (_playerClub[playerId] != clubId) continue;
            delete _playerClub[playerId];
            _leftDuringSweep.push(playerId);
        }

        for (uint256 i; i < squadPlayerIds.length; ++i) {
            bytes32 playerId = squadPlayerIds[i];
            if (playerId == bytes32(0)) revert Errors.ZeroId();
            _playerClub[playerId] = clubId;
        }

        _squadLists[clubId] = SquadList({ clubId: clubId, playerIds: squadPlayerIds });
        emit Events.SquadListUpdated(clubId, squadPlayerIds.length);
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

    function _contains(bytes32[] memory arr, bytes32 value) private pure returns (bool) {
        uint256 n = arr.length;
        for (uint256 i; i < n; ++i) {
            if (arr[i] == value) return true;
        }
        return false;
    }

    // --------------------------------------------
    //  Internal — minutes store helpers
    // --------------------------------------------

    /// @dev Find `seasonId` row or push a new empty `SeasonMinutes`.
    function _getOrCreateSeasonMinutes(
        MinutesStore storage store,
        bytes32 seasonId,
        uint16 seasonStartYear
    ) private returns (SeasonMinutes storage season) {
        uint256 n = store.seasonMinutes.length;
        for (uint256 i; i < n; ++i) {
            if (store.seasonMinutes[i].seasonId == seasonId) {
                return store.seasonMinutes[i];
            }
        }

        store.seasonMinutes.push();
        season = store.seasonMinutes[n];
        season.seasonId = seasonId;
        season.seasonStartYear = seasonStartYear;
    }

    /// @dev Argmax across all seasons' `minsByPosition`. Ties keep the current `expectedPosition`.
    function _deriveExpectedPosition(MinutesStore storage store) private view returns (Position) {
        uint32[POSITION_COUNT] memory totals;
        uint256 n = store.seasonMinutes.length;
        for (uint256 s; s < n; ++s) {
            uint32[POSITION_COUNT] storage mins = store.seasonMinutes[s].minsByPosition;
            for (uint256 i; i < POSITION_COUNT; ++i) {
                totals[i] += mins[i];
            }
        }

        Position best = store.expectedPosition;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 bestMins = totals[uint8(best)];

        for (uint256 i; i < POSITION_COUNT; ++i) {
            uint32 mins = totals[i];
            if (mins > bestMins) {
                bestMins = mins;
                // forge-lint: disable-next-line(unsafe-typecast)
                best = Position(uint8(i));
            }
        }
        return best;
    }
}
