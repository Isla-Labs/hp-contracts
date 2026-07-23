// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { CreReceiver } from "@base/abstract/CreReceiver.sol";
import { RateLimit } from "@base/abstract/RateLimit.sol";

import { IDeployDoppler } from "@base/global/interfaces/data/IDeployDoppler.sol";
import { IAutomator } from "@base/global/interfaces/governance/IAutomator.sol";
import { IPlayerSetRegistry } from "@base/global/interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@base/global/interfaces/ITournamentRegistry.sol";
import { IPbrTreasury } from "@base/global/interfaces/vaults/IPbrTreasury.sol";
import { PlayerStatus, Position } from "@base/global/types/PlayerSetTypes.sol";

import { EligibilityErrors as Errors } from "@base/global/libraries/errors/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@base/global/libraries/events/EligibilityEvents.sol";
import { EligibilityCriteria } from "@data/eligibility/config/EligibilityCriteria.sol";
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
    SquadList,
    SQUAD_FILL_PAGE_DONE
} from "@base/global/types/EligibilityTypes.sol";

/**
 * @title EligibilityVerifier
 * @notice Squad-first eligibility store with a recency-weighted rolling minutes score.
 * @dev Deploy behind `TransparentUpgradeableProxy`. Logic constructor only sets `RateLimit`
 *      cooldown + disables initializers; all domain config is in `initialize`.
 *      Extends `EligibilityCriteria` — cohort thresholds are CATEGORY_ONE updatable.
 *
 *      CRE report path: KeystoneForwarder → `onReport` → `_processReport`.
 *      `initialize` pins `expectedWorkflowId` so only the squad-fill workflow may write.
 *
 *      Report ABI (encoded by CRE): `SquadFillReport` — same tuple layout as the struct fields.
 *      New players get `earliestSeasonStartYear = seasonStartYear` (set once at create).
 *      Optional `metaPlayerIds` / `names` / `symbols` fill `MinutesStore` metadata (first write only).
 *      Daily-active reports also set `clubId` + `squadPlayerIds` to overwrite `SquadList` and
 *      track league membership; at season DONE, players with no club are soft-discontinued.
 *
 *      Rolling score (domestic league calendars only) — ringfenced to `verifyEligibility`:
 *        score = Σ mins_i * λ^(G_now - G_i), λ = 0.97
 *        G(year, round) = Σ finalRound(y) for y in [baseYear, year) + round
 *        (`finalRound` from TournamentRegistry; tx-local memory cache during recompute)
 *      `recordAppearances` only stores raw minutes / Appearance[]; it does not touch scores.
 *      The offchain eligibility runner pages `verifyEligibility(offset, limit)`, which recomputes
 *      each player on the page against `G_now`, then:
 *        - undeployed + above threshold → enqueue deploy cohorts to `DeployDoppler`
 *        - deployed + below continuity threshold → discontinue via `Automator` →
 *          `PlayerSetRegistry.setStatus(INACTIVE)`
 *      `verifyEligibility` is globally `rateLimited` — size `cooldown` for page cadence.
 *
 *      Deploy / continuity thresholds: see `EligibilityCriteria` (defaults GK 361 / u21 181 /
 *      outfield 901 / newTransfer 1; continuity omits the newTransfer shortcut).
 *
 *      Privileged registry writes go through `Automator` (proxy holds `CATEGORY_THREE`
 *      on Automator; Automator holds `CATEGORY_THREE` on `PlayerSetRegistry`).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract EligibilityVerifier is Initializable, EligibilityCriteria, CreReceiver, RateLimit {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    IPlayerSetRegistry public playerSetRegistry;
    ITournamentRegistry public tournamentRegistry;
    IDeployDoppler public deployDoppler;
    /// @notice Cat-3 relay for privileged writes (e.g. `PlayerSetRegistry.setStatus`).
    IAutomator public automator;

    /// @dev Domestic-league `tournamentId` whose calendars count toward the rolling score.
    bytes32 public leagueId;

    /// @dev Earliest season start year used as G-index origin (e.g. 2024).
    uint16 public baseYear;

    /// @notice Sole address allowed to call `recordAppearances` (PpmVerifier).
    address public ppmVerifier;

    /// @dev Max distinct season years cached in one recompute (memory).
    uint256 private constant _FINAL_ROUND_CACHE_CAP = 16;

    /// @dev Tx-local cache: `TournamentRegistry.getFinalRound(leagueId, year)`.
    struct FinalRoundCache {
        uint16[_FINAL_ROUND_CACHE_CAP] seasonYears;
        uint32[_FINAL_ROUND_CACHE_CAP] finals;
        uint8 len;
    }

    mapping(bytes32 playerId => MinutesStore) private _minutesStore;

    bytes32[] private _playerIds;
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

    // --------------------------------------------
    //  Construction / initialization
    // --------------------------------------------

    /// @param cooldown_ Global cooldown for `verifyEligibility` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(uint256 cooldown_) RateLimit(cooldown_) {
        _disableInitializers();
    }

    /**
     * @notice Initialize proxy storage (call via `TransparentUpgradeableProxy` constructor data).
     * @param constitutionalTimelock_ `ConstitutionalTimelock` — `CATEGORY_ONE` threshold updates.
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE` on criteria.
     * @param forwarder_ Chainlink `KeystoneForwarder` for this chain.
     * @param expectedWorkflowId_ Squad-fill CRE workflow id (required; non-zero).
     * @param playerSetRegistry_ Canonical registry used to skip already-deployed markets.
     * @param tournamentRegistry_ Season calendars + treasury lookup for the league clock.
     * @param ppmVerifier_ Authorized minutes ingest caller (PPMVerifier; required; non-zero).
     * @param deployDoppler_ Waiting-room receiver for eligible cohorts (required; non-zero).
     * @param automator_ Cat-3 `Automator` relay (this proxy must be granted `CATEGORY_THREE` on it).
     * @param leagueId_ Domestic-league tournament id (score filter + clock source).
     * @param baseYear_ G-index origin season start year.
     */
    function initialize(
        address constitutionalTimelock_,
        address dao_,
        address forwarder_,
        bytes32 expectedWorkflowId_,
        address playerSetRegistry_,
        address tournamentRegistry_,
        address ppmVerifier_,
        address deployDoppler_,
        address automator_,
        bytes32 leagueId_,
        uint16 baseYear_
    ) external initializer {
        if (expectedWorkflowId_ == bytes32(0)) revert Errors.ZeroWorkflowId();
        if (
            ppmVerifier_ == address(0) || playerSetRegistry_ == address(0)
                || tournamentRegistry_ == address(0) || deployDoppler_ == address(0)
                || automator_ == address(0)
        ) {
            revert Errors.ZeroAddress();
        }
        if (leagueId_ == bytes32(0) || baseYear_ == 0) revert Errors.ZeroId();

        __EligibilityCriteria_init(constitutionalTimelock_, dao_);
        __CreReceiver_init(forwarder_);
        _setExpectedWorkflowId(expectedWorkflowId_);

        ppmVerifier = ppmVerifier_;
        playerSetRegistry = IPlayerSetRegistry(playerSetRegistry_);
        tournamentRegistry = ITournamentRegistry(tournamentRegistry_);
        deployDoppler = IDeployDoppler(deployDoppler_);
        automator = IAutomator(automator_);
        leagueId = leagueId_;
        baseYear = baseYear_;
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc CreReceiver
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl, CreReceiver)
        returns (bool)
    {
        return AccessControl.supportsInterface(interfaceId) || CreReceiver.supportsInterface(interfaceId);
    }

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
    function playersMissingMetadata(bytes32[] calldata mdPlayerIds)
        external
        view
        returns (bytes32[] memory missing)
    {
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

    // --------------------------------------------
    //  Eligibility (offchain runner)
    // --------------------------------------------

    /**
     * @notice Recompute weighted scores for a page; deploy new markets / discontinue under-threshold ones.
     * @dev Sole write path for `weightedScoreWad`. Public (anyone may run the page).
     *      1) Replay domestic-league `Appearance[]` → score at `G_now` for every player on the page
     *      2) Undeployed + eligible → deploy cohorts; deployed + below continuity → `toDiscontinue`
     *      3) `deployDoppler.enqueueEligible` for deploy cohorts;
     *         discontinue via `automator.executeAutomation` → `setStatus(INACTIVE)`
     *      `groups.newTransfers` = DeployDoppler newTransfer / backFromLoan flag.
     *      Continuity uses GK/u21/outfield thresholds only (not the newTransfer ≥ 1 shortcut).
     */
    function verifyEligibility(uint256 offset, uint256 limit)
        external
        rateLimited
        returns (EligibilityGroups memory groups)
    {
        uint256 total = _playerIds.length;
        if (offset >= total || limit == 0) {
            return groups;
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

        FinalRoundCache memory frCache;
        uint32 gNow = _globalRoundNow(frCache);
        uint256 synced;

        // Pass 0: ringfenced score sync for the whole page (including idle / already-deployed).
        for (uint256 i = offset; i < end; ++i) {
            bytes32 playerId = _playerIds[i];
            MinutesStore storage store = _minutesStore[playerId];
            _recomputeWeightedScore(store, gNow, frCache);
            unchecked {
                ++synced;
            }
            emit Events.WeightedScoreUpdated(playerId, store.weightedScoreWad);
        }
        emit Events.WeightedScoresSynced(offset, limit, synced, gNow);

        uint256 gkCount;
        uint256 u21Count;
        uint256 outCount;
        uint256 ntCount;
        uint256 discCount;

        // Pass 1: size deploy cohorts + discontinue set for this page.
        for (uint256 i = offset; i < end; ++i) {
            bytes32 playerId = _playerIds[i];

            if (playerSetRegistry.playerExists(playerId)) {
                if (playerSetRegistry.getPlayerSet(playerId).status == PlayerStatus.INACTIVE) continue;
                (bool stillActive,) = _evaluateContinuity(playerId);
                if (!stillActive) {
                    unchecked {
                        ++discCount;
                    }
                }
                continue;
            }

            (bool eligible, EligibilityBucket bucket,) = _evaluateForDeploy(playerId);
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
        groups.toDiscontinue = new bytes32[](discCount);

        uint256 gkIdx;
        uint256 u21Idx;
        uint256 outIdx;
        uint256 ntIdx;
        uint256 discIdx;

        // Pass 2: fill.
        for (uint256 i = offset; i < end; ++i) {
            bytes32 playerId = _playerIds[i];

            if (playerSetRegistry.playerExists(playerId)) {
                if (playerSetRegistry.getPlayerSet(playerId).status == PlayerStatus.INACTIVE) continue;
                (bool stillActive, uint32 effectiveMins) = _evaluateContinuity(playerId);
                if (stillActive) continue;

                groups.toDiscontinue[discIdx] = playerId;
                unchecked {
                    ++discIdx;
                }
                _discontinue(playerId);
                emit Events.PlayerDiscontinued(playerId, effectiveMins);
                continue;
            }

            (bool eligible, EligibilityBucket bucket,) = _evaluateForDeploy(playerId);
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

        // Pass 3: hand off deploy cohorts to DeployDoppler waiting room (skip empty pages).
        if (gkCount + u21Count + outCount + ntCount != 0) {
            deployDoppler.enqueueEligible(groups);
        }
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
     *      none (`_playerClub == 0`) has left the league. If still active in PlayerSetRegistry → INACTIVE.
     *      Intra-league transfers re-acquire `_playerClub` before DONE and are skipped.
     */
    function _finalizeLeagueRemovals() private {
        uint256 n = _leftDuringSweep.length;
        for (uint256 i; i < n; ++i) {
            bytes32 playerId = _leftDuringSweep[i];
            if (_playerClub[playerId] != bytes32(0)) continue;
            if (!playerSetRegistry.playerExists(playerId)) continue;
            if (playerSetRegistry.getPlayerSet(playerId).status == PlayerStatus.INACTIVE) continue;

            _discontinue(playerId);
            emit Events.PlayerLeftLeague(playerId);
        }
        delete _leftDuringSweep;
    }

    function _contains(bytes32[] memory arr, bytes32 value) private pure returns (bool) {
        uint256 n = arr.length;
        for (uint256 i; i < n; ++i) {
            if (arr[i] == value) return true;
        }
        return false;
    }

    // --------------------------------------------
    //  Internal — eligibility
    // --------------------------------------------

    /// @dev Soft-discontinue via Automator relay (`msg.sender` on registry = Automator).
    function _discontinue(bytes32 playerId) private {
        automator.executeAutomation(
            address(playerSetRegistry),
            0,
            abi.encodeCall(IPlayerSetRegistry.setStatus, (playerId, PlayerStatus.INACTIVE))
        );
    }

    /**
     * @dev Deploy path. Uses stored `weightedScoreWad` (fresh after pass 0).
     *      missing DOB → false;
     *      newTransfer/backFromLoan (earliestSeasonStartYear == current) → `thresholdNewTransfer`;
     *      else continuity gates (`thresholdGk` / `thresholdUnder21` / `thresholdOutfield`).
     */
    function _evaluateForDeploy(bytes32 playerId)
        private
        view
        returns (bool eligible, EligibilityBucket bucket, uint32 effectiveMins)
    {
        MinutesStore storage store = _minutesStore[playerId];
        if (store.birthDate == 0) {
            return (false, EligibilityBucket.None, 0);
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        effectiveMins = uint32(store.weightedScoreWad / SCORE_WAD);

        // DeployDoppler flag: newTransfer / backFromLoan for the current season.
        if (store.earliestSeasonStartYear == _currentSeasonYear()) {
            bucket = EligibilityBucket.NewTransfer;
            eligible = effectiveMins >= thresholdNewTransfer;
            return (eligible, bucket, effectiveMins);
        }

        (eligible, bucket) = _continuityGate(store, effectiveMins);
    }

    /**
     * @dev Continuity path for already-deployed markets (no newTransfer shortcut).
     *      missing DOB → false; else GK / u21 / outfield thresholds from `EligibilityCriteria`.
     */
    function _evaluateContinuity(bytes32 playerId)
        private
        view
        returns (bool stillActive, uint32 effectiveMins)
    {
        MinutesStore storage store = _minutesStore[playerId];
        if (store.birthDate == 0) {
            return (false, 0);
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        effectiveMins = uint32(store.weightedScoreWad / SCORE_WAD);
        (stillActive,) = _continuityGate(store, effectiveMins);
    }

    /// @dev Shared GK / u21 / outfield threshold gate (live `EligibilityCriteria` storage).
    function _continuityGate(MinutesStore storage store, uint32 effectiveMins)
        private
        view
        returns (bool ok, EligibilityBucket bucket)
    {
        if (store.expectedPosition == Position.GK) {
            bucket = EligibilityBucket.Goalkeeper;
            ok = effectiveMins >= thresholdGk;
            return (ok, bucket);
        }

        if (_ageYears(store.birthDate) < under21Age) {
            bucket = EligibilityBucket.Under21;
            ok = effectiveMins >= thresholdUnder21;
            return (ok, bucket);
        }

        bucket = EligibilityBucket.Outfield;
        ok = effectiveMins >= thresholdOutfield;
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

    /// @dev `TournamentRegistry.getFinalRound`; cached in `frCache` for the call.
    function _finalRound(uint16 year, FinalRoundCache memory frCache) private view returns (uint32 fr) {
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
    function _toGlobalRound(uint16 year, uint32 round, FinalRoundCache memory frCache)
        private
        view
        returns (uint32)
    {
        if (year <= baseYear) return round;

        uint256 acc;
        for (uint16 y = baseYear; y < year;) {
            acc += _finalRound(y, frCache);
            unchecked {
                ++y;
            }
        }
        // cumulative finalRounds + round stay well below uint32 max for league calendars
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(acc + uint256(round));
    }

    function _globalRoundNow(FinalRoundCache memory frCache) private view returns (uint32) {
        address treasury = tournamentRegistry.getPbrTreasury(leagueId);
        if (treasury == address(0)) revert Errors.ZeroAddress();
        (uint16 season, uint32 active,) = IPbrTreasury(treasury).getCursors();
        if (season == 0 || active == 0) revert Errors.ZeroId();
        return _toGlobalRound(season, active, frCache);
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
    function _computeWeightedScoreWad(MinutesStore storage store, uint32 gNow, FinalRoundCache memory frCache)
        private
        view
        returns (uint256 scoreWad)
    {
        uint256 n = store.seasonMinutes.length;

        for (uint256 s; s < n; ++s) {
            SeasonMinutes storage season = store.seasonMinutes[s];
            if (!_isLeagueSeason(season.seasonId, season.seasonStartYear)) continue;

            uint256 aLen = season.appearances.length;
            for (uint256 a; a < aLen; ++a) {
                Appearance storage app = season.appearances[a];
                if (app.minsPlayed == 0) continue;

                uint32 gApp = _toGlobalRound(season.seasonStartYear, app.roundNumber, frCache);
                uint32 age = gNow > gApp ? gNow - gApp : 0;
                scoreWad += _decay(uint256(app.minsPlayed) * SCORE_WAD, age);
            }
        }
    }

    /// @dev Write path used by `verifyEligibility`.
    function _recomputeWeightedScore(MinutesStore storage store, uint32 gNow, FinalRoundCache memory frCache)
        private
    {
        store.weightedScoreWad = _computeWeightedScoreWad(store, gNow, frCache);
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
