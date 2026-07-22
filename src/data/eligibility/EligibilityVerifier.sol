// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CreReceiver } from "@base/abstract/CreReceiver.sol";
import { EligibilityErrors as Errors } from "@base/global/libraries/errors/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@base/global/libraries/events/EligibilityEvents.sol";
import { IPlayerSetRegistry } from "@base/global/interfaces/IPlayerSetRegistry.sol";
import { Position } from "@base/global/types/PlayerSetTypes.sol";
import {
    Appearance,
    EligibilityBucket,
    EligibilityGroups,
    MinutesStore,
    POSITION_COUNT,
    SeasonMinutes,
    SQUAD_FILL_PAGE_DONE,
    THRESHOLD_GK,
    THRESHOLD_OUTFIELD,
    THRESHOLD_UNDER_21,
    UNDER_21_AGE
} from "@src/data/eligibility/types/EligibilityTypes.sol";

/**
 * @title EligibilityVerifier2
 * @notice Squad-first eligibility store: CRE upserts `birthDate` from raw SP squads pages;
 *         season minutes are filled later by the PPM path. Name/symbol deferred to DeployDoppler.
 * @dev CRE report path: KeystoneForwarder → `onReport` → `_processReport`.
 *      Constructor pins `expectedWorkflowId` so only the squad-fill workflow may write.
 *
 *      Report ABI (encoded by CRE):
 *        `(bytes32 seasonId, uint16 seasonStartYear, uint16 pageFetched, uint16 nextPage,
 *          bytes32[] playerIds, uint256[] birthDates)`
 *      New players get `earliestSeasonStartYear = seasonStartYear` (set once at create).
 *
 *      `squadFillPage[seasonId]`:
 *        - `0` = not started (next SP `_pgNm` is 1)
 *        - `1..999` = next `_pgNm` to fetch
 *        - `SQUAD_FILL_PAGE_DONE` (1000) = season sweep complete
 *
 *      Historical seasons stay at DONE. Active seasons (chosen by CRE from wall-clock year)
 *      may restart from `_pgNm = 1` after DONE for a daily resweep; `lastSquadFillSweepAt`
 *      records when DONE was last reached.
 *
 *      Minutes ingest: `recordAppearances` (gated by `appearancesCaller`, not squad-fill CRE).
 *      Players must already exist from squad-fill; find-or-push `SeasonMinutes` per calendar.
 *
 *      Eligibility (same thresholds as v1 / edge fn): GK ≥ 361, under-21 ≥ 181, else ≥ 901.
 *      `totalMins` sums across all `seasonMinutes` rows for now (season-scoped rules TBD).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract EligibilityVerifier2 is CreReceiver {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    IPlayerSetRegistry public immutable playerSetRegistry;

    mapping(bytes32 playerId => MinutesStore) private _minutesStore;

    bytes32[] private _playerIds;
    mapping(bytes32 playerId => bool) private _tracked;

    /// @dev Per-calendar cursor for squad-fill SP pagination (`seasonId` = calendar HPID).
    mapping(bytes32 seasonId => uint16 page) private _squadFillPage;

    /// @dev Timestamp when `seasonId` last transitioned to `SQUAD_FILL_PAGE_DONE`.
    mapping(bytes32 seasonId => uint256) private _lastSquadFillSweepAt;

    /// @dev Sole address allowed to call `recordAppearances` (PPM / DMS writer).
    address private immutable _APPEARANCES_CALLER;

    // --------------------------------------------
    //  Construction
    // --------------------------------------------

    /// @param forwarder_ Chainlink `KeystoneForwarder` for this chain.
    /// @param expectedWorkflowId_ Squad-fill CRE workflow id (required; non-zero).
    /// @param appearancesCaller_ Authorized minutes ingest caller (required; non-zero).
    /// @param playerSetRegistry_ Canonical registry used to skip already-deployed markets.
    constructor(
        address forwarder_,
        bytes32 expectedWorkflowId_,
        address appearancesCaller_,
        address playerSetRegistry_
    ) CreReceiver(forwarder_) {
        if (expectedWorkflowId_ == bytes32(0)) revert Errors.ZeroWorkflowId();
        if (appearancesCaller_ == address(0) || playerSetRegistry_ == address(0)) revert Errors.ZeroAddress();
        _setExpectedWorkflowId(expectedWorkflowId_);
        _APPEARANCES_CALLER = appearancesCaller_;
        playerSetRegistry = IPlayerSetRegistry(playerSetRegistry_);
    }

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

    function playerExists(bytes32 playerId) external view returns (bool) {
        return _tracked[playerId];
    }

    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory) {
        return _minutesStore[playerId];
    }

    /// @notice Next SP `_pgNm` to fetch for `seasonId`, or `SQUAD_FILL_PAGE_DONE` if complete.
    /// @dev `0` means not started — CRE should fetch `_pgNm = 1`.
    function getSquadFillPage(bytes32 seasonId) external view returns (uint16) {
        return _squadFillPage[seasonId];
    }

    function getLastSquadFillSweepAt(bytes32 seasonId) external view returns (uint256) {
        return _lastSquadFillSweepAt[seasonId];
    }

    /// @notice Resolves the SP `_pgNm` CRE should request (`0` → `1`; done → `done=true`).
    function nextSquadFillPageToFetch(bytes32 seasonId) external view returns (uint16 pageToFetch, bool done) {
        uint16 stored = _squadFillPage[seasonId];
        if (stored == SQUAD_FILL_PAGE_DONE) {
            return (0, true);
        }
        return (stored == 0 ? 1 : stored, false);
    }

    function getAppearancesCaller() external view returns (address) {
        return _APPEARANCES_CALLER;
    }

    function totalMinsPlayed(bytes32 playerId) external view returns (uint32) {
        return _totalMins(_minutesStore[playerId]);
    }

    // --------------------------------------------
    //  Eligibility
    // --------------------------------------------

    /// @notice Page over tracked players and return undeployed candidates that clear their cohort threshold.
    /// @dev Skips unset `birthDate` and any `playerId` already present in `PlayerSetRegistry`.
    function verifyEligibility(uint256 offset, uint256 limit)
        external
        view
        returns (EligibilityGroups memory groups)
    {
        uint256 total = _playerIds.length;
        if (offset >= total || limit == 0) {
            return groups;
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

        uint256 gkCount;
        uint256 u21Count;
        uint256 outCount;

        // Pass 1: size cohorts for this page.
        for (uint256 i = offset; i < end; ++i) {
            bytes32 playerId = _playerIds[i];
            if (playerSetRegistry.playerExists(playerId)) continue;

            (bool eligible, EligibilityBucket bucket,) = _evaluate(playerId);
            if (!eligible) continue;

            if (bucket == EligibilityBucket.Goalkeeper) {
                unchecked {
                    ++gkCount;
                }
            } else if (bucket == EligibilityBucket.Under21) {
                unchecked {
                    ++u21Count;
                }
            } else if (bucket == EligibilityBucket.Outfield) {
                unchecked {
                    ++outCount;
                }
            }
        }

        groups.goalkeepers = new bytes32[](gkCount);
        groups.under21 = new bytes32[](u21Count);
        groups.outfield = new bytes32[](outCount);

        uint256 gkIdx;
        uint256 u21Idx;
        uint256 outIdx;

        // Pass 2: fill.
        for (uint256 i = offset; i < end; ++i) {
            bytes32 playerId = _playerIds[i];
            if (playerSetRegistry.playerExists(playerId)) continue;

            (bool eligible, EligibilityBucket bucket,) = _evaluate(playerId);
            if (!eligible) continue;

            if (bucket == EligibilityBucket.Goalkeeper) {
                groups.goalkeepers[gkIdx] = playerId;
                unchecked {
                    ++gkIdx;
                }
            } else if (bucket == EligibilityBucket.Under21) {
                groups.under21[u21Idx] = playerId;
                unchecked {
                    ++u21Idx;
                }
            } else if (bucket == EligibilityBucket.Outfield) {
                groups.outfield[outIdx] = playerId;
                unchecked {
                    ++outIdx;
                }
            }
        }
    }

    /// @notice Single-player check (does not filter on deployment status).
    function isEligible(bytes32 playerId)
        external
        view
        returns (bool eligible, EligibilityBucket bucket, uint32 totalMins)
    {
        return _evaluate(playerId);
    }

    // --------------------------------------------
    //  Minutes ingest (PPM / DMS)
    // --------------------------------------------

    /// @notice Accumulate appearance minutes into an existing player's `SeasonMinutes` row.
    /// @dev Squad-fill must have created the `MinutesStore` already. No DOB enqueue.
    ///      One batch = one calendar (`seasonId` / `seasonStartYear`); each row carries its `roundNumber`.
    function recordAppearances(
        bytes32 seasonId,
        uint16 seasonStartYear,
        Appearance[] calldata appearances
    ) external {
        if (msg.sender != _APPEARANCES_CALLER) revert Errors.Unauthorized();
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
    function _processReport(bytes calldata, bytes calldata report) internal override {
        (
            bytes32 seasonId,
            uint16 seasonStartYear,
            uint16 pageFetched,
            uint16 nextPage,
            bytes32[] memory playerIds_,
            uint256[] memory birthDates
        ) = abi.decode(report, (bytes32, uint16, uint16, uint16, bytes32[], uint256[]));

        if (seasonId == bytes32(0) || seasonStartYear == 0) revert Errors.ZeroId();
        if (pageFetched == 0 || pageFetched >= SQUAD_FILL_PAGE_DONE) {
            revert Errors.InvalidSquadFillNextPage(pageFetched, nextPage);
        }
        if (nextPage == 0 || nextPage > SQUAD_FILL_PAGE_DONE) {
            revert Errors.InvalidSquadFillNextPage(pageFetched, nextPage);
        }
        // Allow stay-on-page (partial drain), advance, or DONE — not rewind / skip ahead arbitrarily.
        if (!(nextPage == pageFetched || nextPage == pageFetched + 1 || nextPage == SQUAD_FILL_PAGE_DONE)) {
            revert Errors.InvalidSquadFillNextPage(pageFetched, nextPage);
        }

        uint16 stored = _squadFillPage[seasonId];

        if (stored == SQUAD_FILL_PAGE_DONE) {
            // Active-season daily resweep: only restart from page 1.
            if (pageFetched != 1) revert Errors.SquadFillSeasonDone(seasonId);
        } else {
            uint16 expectedFetch = stored == 0 ? 1 : stored;
            if (pageFetched != expectedFetch) {
                revert Errors.SquadFillPageMismatch(seasonId, expectedFetch, pageFetched);
            }
        }

        uint256 length = playerIds_.length;
        if (length != birthDates.length) revert Errors.LengthMismatch(length, birthDates.length);

        uint256 created;
        uint256 skipped;

        for (uint256 i; i < length; ++i) {
            bytes32 playerId = playerIds_[i];
            if (playerId == bytes32(0)) revert Errors.ZeroId();

            if (_tracked[playerId]) {
                unchecked {
                    ++skipped;
                }
                continue;
            }

            uint256 birthDate = birthDates[i];
            if (birthDate == 0) revert Errors.ZeroBirthDate(playerId);

            MinutesStore storage store = _minutesStore[playerId];
            store.birthDate = birthDate;
            store.earliestSeasonStartYear = seasonStartYear;
            // `expectedPosition` defaults to Position(0); `seasonMinutes` stays empty until PPM.

            _tracked[playerId] = true;
            _playerIds.push(playerId);

            unchecked {
                ++created;
            }

            emit Events.SquadPlayerCreated(playerId, birthDate);
        }

        _squadFillPage[seasonId] = nextPage;
        if (nextPage == SQUAD_FILL_PAGE_DONE) {
            _lastSquadFillSweepAt[seasonId] = block.timestamp;
        }

        emit Events.SquadFillPageUpdated(seasonId, stored, nextPage);
        emit Events.SquadPlayersCreated(seasonId, pageFetched, created, skipped);
    }

    // --------------------------------------------
    //  Internal
    // --------------------------------------------

    /**
     * @dev Mirrors v1 / original edge fn:
     *      missing DOB → false; GK → 361; age < 21 → 181; else → 901.
     *      Age uses whole years from unix DOB (`(now - birth) / 365 days`).
     *      `totalMins` is the sum across all `seasonMinutes` rows.
     */
    function _evaluate(bytes32 playerId)
        private
        view
        returns (bool eligible, EligibilityBucket bucket, uint32 totalMins)
    {
        MinutesStore storage store = _minutesStore[playerId];
        totalMins = _totalMins(store);

        if (store.birthDate == 0) {
            return (false, EligibilityBucket.None, totalMins);
        }

        if (store.expectedPosition == Position.GK) {
            bucket = EligibilityBucket.Goalkeeper;
            eligible = totalMins >= THRESHOLD_GK;
            return (eligible, bucket, totalMins);
        }

        if (_ageYears(store.birthDate) < UNDER_21_AGE) {
            bucket = EligibilityBucket.Under21;
            eligible = totalMins >= THRESHOLD_UNDER_21;
            return (eligible, bucket, totalMins);
        }

        bucket = EligibilityBucket.Outfield;
        eligible = totalMins >= THRESHOLD_OUTFIELD;
    }

    function _totalMins(MinutesStore storage store) private view returns (uint32 total) {
        uint256 n = store.seasonMinutes.length;
        for (uint256 s; s < n; ++s) {
            total += store.seasonMinutes[s].totalMinutes;
        }
    }

    /// @dev Whole years since unix DOB; leap years are ignored (same spirit as a simple day-count age).
    function _ageYears(uint256 birthDate) private view returns (uint256) {
        if (birthDate == 0 || birthDate >= block.timestamp) return 0;
        return (block.timestamp - birthDate) / 365 days;
    }

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
