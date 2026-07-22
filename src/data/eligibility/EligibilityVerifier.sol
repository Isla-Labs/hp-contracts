// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CreReceiver } from "@base/abstract/CreReceiver.sol";
import { EligibilityErrors as Errors } from "@base/global/libraries/errors/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@base/global/libraries/events/EligibilityEvents.sol";
import { IDeployDoppler } from "@base/global/interfaces/data/IDeployDoppler.sol";
import { IPlayerSetRegistry } from "@base/global/interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@base/global/interfaces/ITournamentRegistry.sol";
import { IPbrTreasury } from "@base/global/interfaces/vaults/IPbrTreasury.sol";
import { Position } from "@base/global/types/PlayerSetTypes.sol";
import {
    Appearance,
    EligibilityBucket,
    EligibilityGroups,
    LAMBDA_WAD,
    MinutesStore,
    POSITION_COUNT,
    SCORE_WAD,
    SeasonMinutes,
    SquadFillReport,
    SQUAD_FILL_PAGE_DONE,
    THRESHOLD_GK,
    THRESHOLD_NEW_TRANSFER,
    THRESHOLD_OUTFIELD,
    THRESHOLD_UNDER_21,
    UNDER_21_AGE
} from "@src/data/eligibility/types/EligibilityTypes.sol";

/**
 * @title EligibilityVerifier2
 * @notice Squad-first eligibility store with a recency-weighted rolling minutes score.
 * @dev CRE report path: KeystoneForwarder → `onReport` → `_processReport`.
 *      Constructor pins `expectedWorkflowId` so only the squad-fill workflow may write.
 *
 *      Report ABI (encoded by CRE): `SquadFillReport` — same tuple layout as the struct fields.
 *      New players get `earliestSeasonStartYear = seasonStartYear` (set once at create).
 *
 *      Rolling score (domestic league calendars only) — ringfenced to `verifyEligibility`:
 *        score = Σ mins_i * λ^(G_now - G_i), λ = 0.97
 *        G(year, round) = (year - baseYear) * roundsPerSeason + round
 *      `recordAppearances` only stores raw minutes / Appearance[]; it does not touch scores.
 *      The offchain eligibility runner pages `verifyEligibility(offset, limit)`, which recomputes
 *      each player on the page against `G_now`, enqueues cohorts to `DeployDoppler`, and returns them.
 *
 *      Cohorts / thresholds (effective minutes ≈ stored score / 1e18):
 *        newTransfer / backFromLoan (DeployDoppler flag):
 *          pending: weightedScoreWad == 0 && earliestSeasonStartYear == currentSeasonYear
 *          eligible path (≥ 1): earliestSeasonStartYear == currentSeasonYear
 *        GK ≥ 361, under-21 ≥ 181, else ≥ 901.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract EligibilityVerifier2 is CreReceiver {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    IPlayerSetRegistry public immutable playerSetRegistry;
    ITournamentRegistry public immutable tournamentRegistry;
    IDeployDoppler public immutable deployDoppler;

    /// @dev Domestic-league `tournamentId` whose calendars count toward the rolling score.
    bytes32 public immutable leagueId;

    /// @dev Earliest season start year used as G-index origin (e.g. 2024).
    uint16 public immutable baseYear;

    /// @dev Fixed season stride for G (e.g. 38 for EPL). Independent of live `finalRound`.
    uint32 public immutable roundsPerSeason;

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
    /// @param appearancesCaller_ Authorized minutes ingest caller (PpmVerifier; required; non-zero).
    /// @param playerSetRegistry_ Canonical registry used to skip already-deployed markets.
    /// @param tournamentRegistry_ Season calendars + treasury lookup for the league clock.
    /// @param deployDoppler_ Waiting-room receiver for eligible cohorts (required; non-zero).
    /// @param leagueId_ Domestic-league tournament id (score filter + clock source).
    /// @param baseYear_ G-index origin season start year.
    /// @param roundsPerSeason_ Fixed rounds per season for G (e.g. 38).
    constructor(
        address forwarder_,
        bytes32 expectedWorkflowId_,
        address appearancesCaller_,
        address playerSetRegistry_,
        address tournamentRegistry_,
        address deployDoppler_,
        bytes32 leagueId_,
        uint16 baseYear_,
        uint32 roundsPerSeason_
    ) CreReceiver(forwarder_) {
        if (expectedWorkflowId_ == bytes32(0)) revert Errors.ZeroWorkflowId();
        if (
            appearancesCaller_ == address(0) || playerSetRegistry_ == address(0)
                || tournamentRegistry_ == address(0) || deployDoppler_ == address(0)
        ) {
            revert Errors.ZeroAddress();
        }
        if (leagueId_ == bytes32(0) || baseYear_ == 0 || roundsPerSeason_ == 0) revert Errors.ZeroId();

        _setExpectedWorkflowId(expectedWorkflowId_);
        _APPEARANCES_CALLER = appearancesCaller_;
        playerSetRegistry = IPlayerSetRegistry(playerSetRegistry_);
        tournamentRegistry = ITournamentRegistry(tournamentRegistry_);
        deployDoppler = IDeployDoppler(deployDoppler_);
        leagueId = leagueId_;
        baseYear = baseYear_;
        roundsPerSeason = roundsPerSeason_;
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

    /// @notice Stored score from the last `verifyEligibility` page that touched this player.
    function weightedScore(bytes32 playerId) external view returns (uint256 scoreWad, uint32 effectiveMins) {
        scoreWad = _minutesStore[playerId].weightedScoreWad;
        // effective minutes stay well below uint32 max
        // forge-lint: disable-next-line(unsafe-typecast)
        effectiveMins = uint32(scoreWad / SCORE_WAD);
    }

    /// @notice Pending newTransfer / backFromLoan: no league score yet, first seen this season.
    function isPendingSeasonEntrant(bytes32 playerId) external view returns (bool) {
        MinutesStore storage store = _minutesStore[playerId];
        return _isPendingSeasonEntrant(store, _currentSeasonYear());
    }

    // --------------------------------------------
    //  Eligibility (offchain runner)
    // --------------------------------------------

    /**
     * @notice Recompute weighted scores for a page, enqueue eligible cohorts to DeployDoppler, return them.
     * @dev Sole write path for `weightedScoreWad`. Public (anyone may run the page).
     *      1) Replay domestic-league `Appearance[]` → score at `G_now` for every player on the page
     *      2) Cohort-check (skip missing DOB / already-deployed)
     *      3) `deployDoppler.enqueueEligible(groups)` — waiting-room write
     *      `groups.newTransfers` = DeployDoppler newTransfer / backFromLoan flag.
     */
    function verifyEligibility(uint256 offset, uint256 limit) external returns (EligibilityGroups memory groups) {
        uint256 total = _playerIds.length;
        if (offset >= total || limit == 0) {
            return groups;
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

        uint32 gNow = _globalRoundNow();
        uint256 synced;

        // Pass 0: ringfenced score sync for the whole page (including idle / already-deployed).
        for (uint256 i = offset; i < end; ++i) {
            bytes32 playerId = _playerIds[i];
            MinutesStore storage store = _minutesStore[playerId];
            _recomputeWeightedScore(store, gNow);
            unchecked {
                ++synced;
            }
            emit Events.WeightedScoreUpdated(playerId, store.weightedScoreWad, store.scoreAsOfGlobalRound);
        }
        emit Events.WeightedScoresSynced(offset, limit, synced, gNow);

        uint256 gkCount;
        uint256 u21Count;
        uint256 outCount;
        uint256 ntCount;

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
            } else if (bucket == EligibilityBucket.NewTransfer) {
                unchecked {
                    ++ntCount;
                }
            }
        }

        groups.goalkeepers = new bytes32[](gkCount);
        groups.under21 = new bytes32[](u21Count);
        groups.outfield = new bytes32[](outCount);
        groups.newTransfers = new bytes32[](ntCount);

        uint256 gkIdx;
        uint256 u21Idx;
        uint256 outIdx;
        uint256 ntIdx;

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
            } else if (bucket == EligibilityBucket.NewTransfer) {
                groups.newTransfers[ntIdx] = playerId;
                unchecked {
                    ++ntIdx;
                }
            }
        }

        // Pass 3: hand off to DeployDoppler waiting room (skip empty pages).
        if (gkCount + u21Count + outCount + ntCount != 0) {
            deployDoppler.enqueueEligible(groups);
        }
    }

    /// @notice Single-player check (does not filter on deployment status).
    /// @dev View-only appearance replay (no storage write). Runner should use `verifyEligibility`.
    /// @return eligible Whether the recomputed weighted score clears the cohort threshold.
    /// @return bucket Cohort used for the threshold (newTransfer / GK / u21 / outfield).
    /// @return effectiveMins Truncated recomputed weighted score (`scoreWad / 1e18`).
    function isEligible(bytes32 playerId)
        external
        view
        returns (bool eligible, EligibilityBucket bucket, uint32 effectiveMins)
    {
        return _evaluateLive(playerId);
    }

    // --------------------------------------------
    //  Minutes ingest (PPM / DMS)
    // --------------------------------------------

    /// @notice Accumulate appearance minutes into an existing player's `SeasonMinutes` row.
    /// @dev Squad-fill must have created the `MinutesStore` already. No DOB enqueue.
    ///      One batch = one calendar (`seasonId` / `seasonStartYear`); each row carries its `roundNumber`.
    ///      Does not update `weightedScoreWad` — that happens in `verifyEligibility`.
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
            // Pending newTransfer/backFromLoan when this year == treasury season and score stays 0.

            _tracked[playerId] = true;
            _playerIds.push(playerId);

            unchecked {
                ++created;
            }

            emit Events.SquadPlayerCreated(playerId, birthDate);
        }

        _squadFillPage[r.seasonId] = r.nextPage;
        if (r.nextPage == SQUAD_FILL_PAGE_DONE) {
            _lastSquadFillSweepAt[r.seasonId] = block.timestamp;
        }

        emit Events.SquadFillPageUpdated(r.seasonId, stored, r.nextPage);
        emit Events.SquadPlayersCreated(r.seasonId, r.pageFetched, created, skipped);
    }

    // --------------------------------------------
    //  Internal — eligibility
    // --------------------------------------------

    /**
     * @dev Uses stored `weightedScoreWad` (fresh after pass 0 of `verifyEligibility`).
     *      missing DOB → false;
     *      newTransfer/backFromLoan (earliestSeasonStartYear == current) → ≥ 1;
     *      GK → 361; age < 21 → 181; else → 901.
     */
    function _evaluate(bytes32 playerId)
        private
        view
        returns (bool eligible, EligibilityBucket bucket, uint32 effectiveMins)
    {
        MinutesStore storage store = _minutesStore[playerId];
        // effective minutes stay well below uint32 max
        // forge-lint: disable-next-line(unsafe-typecast)
        return _evaluateWithScore(store, uint32(store.weightedScoreWad / SCORE_WAD));
    }

    /// @dev View path for `isEligible`: replay appearances without writing storage.
    function _evaluateLive(bytes32 playerId)
        private
        view
        returns (bool eligible, EligibilityBucket bucket, uint32 effectiveMins)
    {
        MinutesStore storage store = _minutesStore[playerId];
        uint256 scoreWad = _computeWeightedScoreWad(store, _globalRoundNow());
        // forge-lint: disable-next-line(unsafe-typecast)
        return _evaluateWithScore(store, uint32(scoreWad / SCORE_WAD));
    }

    function _evaluateWithScore(MinutesStore storage store, uint32 effectiveMins)
        private
        view
        returns (bool eligible, EligibilityBucket bucket, uint32)
    {
        if (store.birthDate == 0) {
            return (false, EligibilityBucket.None, 0);
        }

        uint16 currentYear = _currentSeasonYear();

        // DeployDoppler flag: newTransfer / backFromLoan.
        // Pending form: weightedScoreWad == 0 && earliest == currentYear.
        // After first league minute, keep the cohort for the season via earliest == currentYear.
        if (store.earliestSeasonStartYear == currentYear) {
            bucket = EligibilityBucket.NewTransfer;
            eligible = effectiveMins >= THRESHOLD_NEW_TRANSFER;
            return (eligible, bucket, effectiveMins);
        }

        if (store.expectedPosition == Position.GK) {
            bucket = EligibilityBucket.Goalkeeper;
            eligible = effectiveMins >= THRESHOLD_GK;
            return (eligible, bucket, effectiveMins);
        }

        if (_ageYears(store.birthDate) < UNDER_21_AGE) {
            bucket = EligibilityBucket.Under21;
            eligible = effectiveMins >= THRESHOLD_UNDER_21;
            return (eligible, bucket, effectiveMins);
        }

        bucket = EligibilityBucket.Outfield;
        eligible = effectiveMins >= THRESHOLD_OUTFIELD;
        return (eligible, bucket, effectiveMins);
    }

    /// @dev `weightedScoreWad == 0 && earliestSeasonStartYear == currentSeasonYear`.
    function _isPendingSeasonEntrant(MinutesStore storage store, uint16 currentYear)
        private
        view
        returns (bool)
    {
        return store.weightedScoreWad == 0 && store.earliestSeasonStartYear == currentYear;
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

    // --------------------------------------------
    //  Internal — rolling score / league clock
    // --------------------------------------------

    function _currentSeasonYear() private view returns (uint16 season) {
        address treasury = tournamentRegistry.getPbrTreasury(leagueId);
        if (treasury == address(0)) revert Errors.ZeroAddress();
        (season,,) = IPbrTreasury(treasury).getCursors();
        if (season == 0) revert Errors.ZeroId();
    }

    function _toGlobalRound(uint16 year, uint32 round) private view returns (uint32) {
        if (year < baseYear) return round;
        return uint32(uint256(year - baseYear) * uint256(roundsPerSeason) + uint256(round));
    }

    function _globalRoundNow() private view returns (uint32) {
        address treasury = tournamentRegistry.getPbrTreasury(leagueId);
        if (treasury == address(0)) revert Errors.ZeroAddress();
        (uint16 season, uint32 active,) = IPbrTreasury(treasury).getCursors();
        if (season == 0 || active == 0) revert Errors.ZeroId();
        return _toGlobalRound(season, active);
    }

    function _decay(uint256 scoreWad, uint32 deltaRounds) private pure returns (uint256) {
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

    /// @dev Full replay of domestic-league appearances → score at `gNow` (view-safe).
    function _computeWeightedScoreWad(MinutesStore storage store, uint32 gNow) private view returns (uint256 scoreWad) {
        uint256 n = store.seasonMinutes.length;

        for (uint256 s; s < n; ++s) {
            SeasonMinutes storage season = store.seasonMinutes[s];
            if (!_isLeagueSeason(season.seasonId, season.seasonStartYear)) continue;

            uint256 aLen = season.appearances.length;
            for (uint256 a; a < aLen; ++a) {
                Appearance storage app = season.appearances[a];
                if (app.minsPlayed == 0) continue;

                uint32 gApp = _toGlobalRound(season.seasonStartYear, app.roundNumber);
                uint32 age = gNow > gApp ? gNow - gApp : 0;
                scoreWad += _decay(uint256(app.minsPlayed) * SCORE_WAD, age);
            }
        }
    }

    /// @dev Write path used by `verifyEligibility`.
    function _recomputeWeightedScore(MinutesStore storage store, uint32 gNow) private {
        store.weightedScoreWad = _computeWeightedScoreWad(store, gNow);
        store.scoreAsOfGlobalRound = gNow;
    }

    function _isLeagueSeason(bytes32 seasonId, uint16 seasonStartYear) private view returns (bool) {
        try tournamentRegistry.getSeasonId(leagueId, seasonStartYear) returns (bytes32 expected) {
            return expected != bytes32(0) && expected == seasonId;
        } catch {
            return false;
        }
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
