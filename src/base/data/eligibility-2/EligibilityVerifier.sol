// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { RateLimit } from "@base/abstract/RateLimit.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { IEligibilityStore2 } from "@interfaces/data/IEligibilityStore2.sol";
import { ITransferLocker } from "@interfaces/governance/ITransferLocker.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";
import { LifecycleReason } from "@types/governance/LifecycleTypes.sol";
import { PlayerStatus, Position } from "@types/PlayerSetTypes.sol";
import { EligibilityEvents as Events } from "@events/data/EligibilityEvents.sol";

import { EligibilityCriteria } from "./base/EligibilityCriteria.sol";
import {
    EligibilityBucket,
    EligibilityGroups,
    MinutesStore,
    SCORE_WAD,
    SquadList,
    VerifySnapshot
} from "@data/eligibility-2/types/EligibilityTypes.sol";

/**
 * @title EligibilityVerifier (eligibility-2)
 * @notice Criteria + rate-limited verify scan; enqueues DopplerLocker / TransferLocker directly.
 * @dev Proxy-initialized. Separation:
 *        - `EligibilityStore` — CVM squads oracle + `recordAppearances` / score math (own proxy)
 *        - `EligibilityCriteria` — owner-tunable thresholds only
 *        - this contract — scan, classify, locker handoff
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract EligibilityVerifier is Initializable, AddressBook, EligibilityCriteria, RateLimit {
    /// @dev Per-player outcome after score sync (page classify).
    enum VerifyAction {
        None,
        DeployGoalkeeper,
        DeployUnder21,
        DeployOutfield,
        DeployNewTransfer,
        Deactivate,
        Reactivate
    }

    /// @notice Minutes / CVM data plane (set once in `initialize`).
    IEligibilityStore2 public store;

    /// @param addressProvider_ Canonical `AddressProvider`.
    /// @param cooldown_ Min seconds between `verifyEligibility` pages.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_, uint256 cooldown_)
        AddressBook(addressProvider_)
        Ownable(msg.sender)
        RateLimit(cooldown_)
    {
        _disableInitializers();
    }

    /**
     * @notice Proxy init: ownership, criteria defaults, wire to `EligibilityStore`.
     * @dev Resolves `ELIGIBILITY_STORE` from AddressProvider (must be registered first).
     */
    function initialize() external initializer {
        address store_ = _getAddress(_addressKey(Addresses.ELIGIBILITY_STORE));

        _transferOwnership(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));
        __EligibilityCriteria_init();
        store = IEligibilityStore2(store_);
    }

    // --------------------------------------------
    //  Eligibility scan
    // --------------------------------------------

    /**
     * @notice Decay page scores to each player's league `G_now`; enqueue deploy / lifecycle sets.
     * @dev Public (rate-limited). Score mass comes from Store `recordAppearances`.
     *      1) Page-local GC: drop `MinutesStore` when `deactivatedAt` ≥ 5 years ago
     *      2) Idle-decay `LeagueMinutes` for `currentLeagueId` → `G_now` (`syncAndSnapshot`)
     *      3) Classify from lean snapshot (current-league score only)
     *      4) Drain SORT change buckets (`_drainChangers`)
     *      5) Enqueue DopplerLocker / TransferLocker directly
     *      Continuity uses `thresholdNewTransfer` when `startYearCurrentLeague` matches
     *      the live season (cross-league tenure / first-year in league).
     */
    function verifyEligibility(
        uint256 offset,
        uint256 limit
    ) external rateLimited returns (EligibilityGroups memory groups) {
        IEligibilityStore2 s = store;
        uint256 total = s.playerCount();
        if (offset >= total || limit == 0) {
            _drainChangers();
            return groups;
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

        // Bound buffers to the initial page window (GC can only shrink `end`).
        uint256 pageCap = end - offset;
        bytes32[] memory gk = new bytes32[](pageCap);
        bytes32[] memory u21 = new bytes32[](pageCap);
        bytes32[] memory outf = new bytes32[](pageCap);
        bytes32[] memory nt = new bytes32[](pageCap);
        bytes32[] memory deact = new bytes32[](pageCap);
        bytes32[] memory react = new bytes32[](pageCap);
        uint32[] memory deactMinsBuf = new uint32[](pageCap);
        uint32[] memory reactMinsBuf = new uint32[](pageCap);

        uint256 gkN;
        uint256 u21N;
        uint256 outN;
        uint256 ntN;
        uint256 deactN;
        uint256 reactN;

        IPlayerSetRegistry registry = _playerSetRegistry();

        for (uint256 i = offset; i < end;) {
            if (s.purgeIfStale(i)) {
                total = s.playerCount();
                if (end > total) end = total;
                continue;
            }

            bytes32 playerId = s.playerIdAt(i);
            VerifySnapshot memory snap = s.syncAndSnapshot(playerId);
            (VerifyAction action, uint32 effectiveMins) = _classify(snap, playerId, registry);

            if (action == VerifyAction.DeployGoalkeeper) {
                gk[gkN] = playerId;
                unchecked {
                    ++gkN;
                }
            } else if (action == VerifyAction.DeployUnder21) {
                u21[u21N] = playerId;
                unchecked {
                    ++u21N;
                }
            } else if (action == VerifyAction.DeployOutfield) {
                outf[outN] = playerId;
                unchecked {
                    ++outN;
                }
            } else if (action == VerifyAction.DeployNewTransfer) {
                nt[ntN] = playerId;
                unchecked {
                    ++ntN;
                }
            } else if (action == VerifyAction.Deactivate) {
                deact[deactN] = playerId;
                deactMinsBuf[deactN] = effectiveMins;
                unchecked {
                    ++deactN;
                }
                emit Events.PlayerDeactivated(playerId, effectiveMins);
            } else if (action == VerifyAction.Reactivate) {
                react[reactN] = playerId;
                reactMinsBuf[reactN] = effectiveMins;
                unchecked {
                    ++reactN;
                }
                emit Events.PlayerReactivateQueued(playerId, effectiveMins);
            }

            unchecked {
                ++i;
            }
        }

        groups.goalkeepers = _compactIds(gk, gkN);
        groups.under21 = _compactIds(u21, u21N);
        groups.outfield = _compactIds(outf, outN);
        groups.newTransfers = _compactIds(nt, ntN);
        groups.toDeactivate = _compactIds(deact, deactN);
        groups.toReactivate = _compactIds(react, reactN);

        if (gkN + u21N + outN + ntN != 0) {
            _enqueueEligible(groups);
        }
        if (deactN != 0) {
            _enqueueLifecycle(
                groups.toDeactivate, LifecycleReason.ContinuityUnderThreshold, _compactMins(deactMinsBuf, deactN)
            );
        }
        if (reactN != 0) {
            _enqueueLifecycle(groups.toReactivate, LifecycleReason.Reactivate, _compactMins(reactMinsBuf, reactN));
        }

        _drainChangers();
    }

    // --------------------------------------------
    //  Views — DopplerLocker metadata oracle (+ thin Store forwards)
    // --------------------------------------------

    /// @notice Name/symbol from Store (DopplerLocker enqueue oracle).
    function getPlayerMetadata(bytes32 playerId)
        external
        view
        returns (string memory name, string memory symbol, bool metadataSet)
    {
        return store.getPlayerMetadata(playerId);
    }

    function playerCount() external view returns (uint256) {
        return store.playerCount();
    }

    function playerIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        return store.playerIds(offset, limit);
    }

    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory) {
        return store.getMinutesStore(playerId);
    }

    function getVerifySnapshot(bytes32 playerId) external view returns (VerifySnapshot memory) {
        return store.getVerifySnapshot(playerId);
    }

    function getSquadList(bytes32 clubId) external view returns (SquadList memory) {
        return store.getSquadList(clubId);
    }

    // --------------------------------------------
    //  AddressBook hooks
    // --------------------------------------------

    function _playerSetRegistry() internal view returns (IPlayerSetRegistry) {
        return IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));
    }

    function _tournamentRegistry() internal view returns (ITournamentRegistry) {
        return ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }

    function _transferLocker() internal view returns (ITransferLocker) {
        return ITransferLocker(_getAddress(_addressKey(Addresses.TRANSFER_LOCKER)));
    }

    // --------------------------------------------
    //  Internal — classify
    // --------------------------------------------

    /**
     * @dev Deployed → continuity lifecycle; undeployed → deploy cohort (or none).
     *      Score = `currentLeague` row only. New-to-league tenure uses `thresholdNewTransfer`.
     */
    function _classify(
        VerifySnapshot memory snap,
        bytes32 playerId,
        IPlayerSetRegistry registry
    ) private view returns (VerifyAction action, uint32 effectiveMins) {
        if (registry.playerExists(playerId)) {
            PlayerStatus status = registry.getPlayerSet(playerId).status;
            bool stillActive;
            (stillActive, effectiveMins) = _evaluateContinuity(snap);

            if (status == PlayerStatus.INACTIVE) {
                if (stillActive) return (VerifyAction.Reactivate, effectiveMins);
                return (VerifyAction.None, 0);
            }
            if (!stillActive) return (VerifyAction.Deactivate, effectiveMins);
            return (VerifyAction.None, 0);
        }

        (bool eligible, EligibilityBucket bucket, uint32 mins) = _evaluateForDeploy(snap);
        if (!eligible) return (VerifyAction.None, 0);
        effectiveMins = mins;

        if (bucket == EligibilityBucket.Goalkeeper) return (VerifyAction.DeployGoalkeeper, mins);
        if (bucket == EligibilityBucket.Under21) return (VerifyAction.DeployUnder21, mins);
        if (bucket == EligibilityBucket.Outfield) return (VerifyAction.DeployOutfield, mins);
        if (bucket == EligibilityBucket.NewTransfer) return (VerifyAction.DeployNewTransfer, mins);
        return (VerifyAction.None, 0);
    }

    /**
     * @dev Deploy path. Uses `currentLeague` score (fresh after sync).
     *      missing DOB / no club → false;
     *      `startYearCurrentLeague ==` current league season → `thresholdNewTransfer`;
     *      else continuity gates.
     */
    function _evaluateForDeploy(VerifySnapshot memory snap)
        private
        view
        returns (bool eligible, EligibilityBucket bucket, uint32 effectiveMins)
    {
        if (snap.birthDate == 0 || snap.currentClubId == bytes32(0) || snap.currentLeagueId == bytes32(0)) {
            return (false, EligibilityBucket.None, 0);
        }

        effectiveMins = _effectiveMins(snap);

        if (_isNewToCurrentLeague(snap)) {
            bucket = EligibilityBucket.NewTransfer;
            eligible = effectiveMins >= thresholdNewTransfer;
            return (eligible, bucket, effectiveMins);
        }

        (eligible, bucket) = _continuityGate(snap, effectiveMins);
    }

    /**
     * @dev Continuity for deployed markets.
     *      Post cross-league move (`startYearCurrentLeague ==` current season): 1-min bar
     *      (`thresholdNewTransfer`) so e.g. Haaland→Madrid reactivates after first appearance.
     *      Otherwise GK / u21 / outfield thresholds.
     */
    function _evaluateContinuity(VerifySnapshot memory snap)
        private
        view
        returns (bool stillActive, uint32 effectiveMins)
    {
        if (snap.birthDate == 0) {
            return (false, 0);
        }

        effectiveMins = _effectiveMins(snap);

        if (_isNewToCurrentLeague(snap)) {
            stillActive = effectiveMins >= thresholdNewTransfer;
            return (stillActive, effectiveMins);
        }

        (stillActive,) = _continuityGate(snap, effectiveMins);
    }

    /// @dev True when this league tenure started in the league's live season year.
    function _isNewToCurrentLeague(VerifySnapshot memory snap) private view returns (bool) {
        uint16 startYear = snap.startYearCurrentLeague;
        if (startYear == 0 || snap.currentLeagueId == bytes32(0)) return false;
        return startYear == _currentSeasonYear(snap.currentLeagueId);
    }

    /// @dev Shared GK / u21 / outfield threshold gate (live `EligibilityCriteria` storage).
    function _continuityGate(
        VerifySnapshot memory snap,
        uint32 effectiveMins
    ) private view returns (bool ok, EligibilityBucket bucket) {
        if (snap.expectedPosition == Position.GK) {
            bucket = EligibilityBucket.Goalkeeper;
            ok = effectiveMins >= thresholdGk;
            return (ok, bucket);
        }

        if (_ageYears(snap.birthDate) < under21Age) {
            bucket = EligibilityBucket.Under21;
            ok = effectiveMins >= thresholdUnder21;
            return (ok, bucket);
        }

        bucket = EligibilityBucket.Outfield;
        ok = effectiveMins >= thresholdOutfield;
    }

    /// @dev Effective minutes from `currentLeague` score only (0 if no row / no league).
    function _effectiveMins(VerifySnapshot memory snap) private pure returns (uint32) {
        if (snap.currentLeagueId == bytes32(0) || snap.currentLeague.leagueId == bytes32(0)) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(snap.currentLeague.weightedScoreWad / SCORE_WAD);
    }

    /// @dev Live season year for `leagueId` (treasury cursors; fallback to Store workflow year).
    function _currentSeasonYear(bytes32 leagueId) private view returns (uint16) {
        address treasury = _tournamentRegistry().getPbrTreasury(leagueId);
        if (treasury == address(0)) return store.workflowControl().currentSeasonStartYear;
        (uint16 season,,) = IPbrTreasury(treasury).getCursors();
        return season == 0 ? store.workflowControl().currentSeasonStartYear : season;
    }

    /// @dev Whole years since unix DOB; leap years ignored.
    function _ageYears(uint256 birthDate) private view returns (uint256) {
        if (birthDate == 0 || birthDate >= block.timestamp) return 0;
        return (block.timestamp - birthDate) / 365 days;
    }

    // --------------------------------------------
    //  Internal — SORT change buckets → TransferLocker
    // --------------------------------------------

    /**
     * @dev Drain SORT pending arrays from Store:
     *      - left league → TransferLocker `LeftLeague` (deployed only)
     *      - league changed → TransferLocker `ChangedLeague` (deployed only)
     *      - club changed → clear only (events already emitted on SORT)
     */
    function _drainChangers() private {
        IEligibilityStore2 s = store;
        IPlayerSetRegistry registry = _playerSetRegistry();

        _enqueueDeployedPending(s.takePendingLeftLeague(), LifecycleReason.LeftLeague, registry);
        _enqueueDeployedPending(s.takePendingLeagueChanged(), LifecycleReason.ChangedLeague, registry);
        // Club moves: membership already updated on SORT; drop the staging array.
        s.takePendingClubChanged();
    }

    function _enqueueDeployedPending(
        bytes32[] memory pending,
        LifecycleReason reason,
        IPlayerSetRegistry registry
    ) private {
        uint256 n = pending.length;
        if (n == 0) return;

        bytes32[] memory deployed = new bytes32[](n);
        uint256 count;
        for (uint256 i; i < n; ++i) {
            if (!registry.playerExists(pending[i])) continue;
            deployed[count] = pending[i];
            unchecked {
                ++count;
            }
        }
        if (count == 0) return;

        bytes32[] memory ids = _compactIds(deployed, count);
        uint32[] memory zeros = new uint32[](count);
        _enqueueLifecycle(ids, reason, zeros);
    }

    function _enqueueEligible(EligibilityGroups memory groups) private {
        // TODO(eligibility-2): flatten deploy cohorts into `(seasonId, playerIds)` and call
        // `IDopplerLocker.queueAssets(seasonId, playerIds)` (owner/Orchestrator path).
        groups;
    }

    function _enqueueLifecycle(bytes32[] memory ids, LifecycleReason reason, uint32[] memory effectiveMins) private {
        _transferLocker().enqueueLifecycle(ids, reason, effectiveMins);
    }

    function _compactIds(bytes32[] memory src, uint256 n) private pure returns (bytes32[] memory out) {
        out = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = src[i];
        }
    }

    function _compactMins(uint32[] memory src, uint256 n) private pure returns (uint32[] memory out) {
        out = new uint32[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = src[i];
        }
    }
}
