// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { IReceiver } from "@cre/v1/interfaces/IReceiver.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { CreReceiver } from "@base/abstract/CreReceiver.sol";
import { RateLimit } from "@base/abstract/RateLimit.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { IAutomator } from "@interfaces/governance/IAutomator.sol";
import { IDopplerLocker } from "@interfaces/governance/IDopplerLocker.sol";
import { ITransferLocker } from "@interfaces/governance/ITransferLocker.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";
import { LifecycleReason } from "@types/governance/LifecycleTypes.sol";
import { PlayerStatus, Position } from "@types/PlayerSetTypes.sol";
import { AccessRoles as Roles } from "@roles/AccessRoles.sol";
import { EligibilityErrors as Errors } from "@errors/data/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@events/data/EligibilityEvents.sol";

import { EligibilityCriteria } from "./base/EligibilityCriteria.sol";
import { EligibilityStore } from "./EligibilityStore.sol";
import {
    EligibilityBucket,
    EligibilityGroups,
    LeagueMinutes,
    MinutesStore,
    SCORE_WAD
} from "./types/EligibilityTypes.sol";

/**
 * @title EligibilityVerifier
 * @notice Top layer: AddressBook wiring, ops roles, criteria, rate-limited verify scan.
 * @dev Proxy-initialized. Separation:
 *        - `EligibilityStore` — CRE squads + `recordAppearances` / score math
 *        - `EligibilityCriteria` — governance thresholds only
 *        - this contract — scan, classify, Automator → DopplerLocker / TransferLocker
 *
 *      Squads CRE reports → `onReport` → store `_processReport`.
 *      PpmVerifier → store `recordAppearances`.
 *      `verifyEligibility` decays `LeagueMinutes` for each player's `currentLeagueId`
 *      to that league's `G_now`, then classifies deploy / continuity cohorts.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract EligibilityVerifier is Initializable, AddressBook, EligibilityStore, EligibilityCriteria, RateLimit {
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

    /// @dev Drop `MinutesStore` rows with `deactivatedAt` at least this old (page-local GC).
    uint256 internal constant STALE_AFTER = 5 * 365 days;

    /// @param addressProvider_ Canonical `AddressProvider`.
    /// @param cooldown_ Min seconds between `verifyEligibility` pages.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_, uint256 cooldown_) AddressBook(addressProvider_) RateLimit(cooldown_) {
        _disableInitializers();
    }

    /**
     * @notice Proxy init: roles, criteria defaults, CRE forwarder + workflow id, year clocks.
     * @param workflowId_ Expected CRE workflow id (squads `eligibility-store`).
     * @param baseYear_ Sets `scoreBaseYear` (G-index origin) and initial `currentSeasonStartYear`.
     */
    function initialize(bytes32 workflowId_, uint16 baseYear_) external initializer {
        if (workflowId_ == bytes32(0)) revert Errors.ZeroWorkflowId();
        if (baseYear_ == 0) revert Errors.ZeroId();

        address dao_ = _getAddress(_addressKey(Addresses.DAO));
        address constitutionalTimelock_ = _getAddress(_addressKey(Addresses.CONSTITUTIONAL_TIMELOCK));
        address automator_ = _getAddress(_addressKey(Addresses.AUTOMATOR));
        address forwarder_ = _getAddress(_addressKey(Addresses.CRE_FORWARDER));

        __EligibilityCriteria_init(constitutionalTimelock_, dao_);
        _grantRole(Roles.CATEGORY_THREE, automator_);

        __CreReceiver_init(forwarder_);
        _setExpectedWorkflowId(workflowId_);
        _setScoreBaseYear(baseYear_);
        _setCurrentSeasonStartYear(baseYear_);
    }

    // --------------------------------------------
    //  Ops — CATEGORY_THREE (Automator) / CATEGORY_ONE
    // --------------------------------------------

    /// @notice Manually queue a league's seasons (oldest→newest). Prefer CRE `SYNC_LEAGUE`.
    function queueLeague(
        bytes32 leagueId,
        bytes32[] calldata seasonIds,
        uint16[] calldata seasonStartYears
    ) external onlyRole(Roles.CATEGORY_THREE) {
        _queueLeague(leagueId, seasonIds, seasonStartYears);
    }

    /// @notice Set / retune `currentSeasonStartYear` while idle (monotonic tick usually via finalize).
    function setCurrentSeasonStartYear(uint16 year) external onlyRole(Roles.CATEGORY_ONE) {
        _setCurrentSeasonStartYear(year);
    }

    function setExpectedWorkflowId(bytes32 workflowId_) external onlyRole(Roles.CATEGORY_ONE) {
        if (workflowId_ == bytes32(0)) revert Errors.ZeroWorkflowId();
        _setExpectedWorkflowId(workflowId_);
    }

    function setForwarderAddress(address forwarder_) external onlyRole(Roles.CATEGORY_ONE) {
        _setForwarderAddress(forwarder_);
    }

    // --------------------------------------------
    //  Eligibility scan
    // --------------------------------------------

    /**
     * @notice Decay page scores to each player's league `G_now`; enqueue deploy / lifecycle sets.
     * @dev Public (rate-limited). Score mass comes from `recordAppearances`.
     *      1) Page-local GC: drop `MinutesStore` when `deactivatedAt` ≥ 5 years ago
     *      2) Idle-decay `LeagueMinutes` for `currentLeagueId` → `G_now`
     *      3) Classify → deploy cohorts / continuity deactivate|reactivate
     *      4) Drain SORT change buckets (`_drainChangers`)
     *      5) Automator → DopplerLocker / TransferLocker
     *      Continuity uses `thresholdNewTransfer` when `startYearCurrentLeague` matches
     *      the live season (cross-league tenure / first-year in league).
     */
    function verifyEligibility(
        uint256 offset,
        uint256 limit
    ) external rateLimited returns (EligibilityGroups memory groups) {
        uint256 total = _playerIds.length;
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
        FinalRoundCache memory frCache;

        for (uint256 i = offset; i < end;) {
            if (_purgeIfStale(i)) {
                if (end > _playerIds.length) end = _playerIds.length;
                continue;
            }

            bytes32 playerId = _playerIds[i];
            _syncPlayerScore(playerId, frCache);

            (VerifyAction action, uint32 effectiveMins) = _classify(playerId, registry);

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
    //  AddressBook → store / scanner hooks
    // --------------------------------------------

    function _ppmVerifier() internal view override returns (address) {
        return _getAddress(_addressKey(Addresses.PPM_VERIFIER));
    }

    function _tournamentRegistry() internal view override returns (ITournamentRegistry) {
        return ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }

    function _playerSetRegistry() internal view returns (IPlayerSetRegistry) {
        return IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));
    }

    function _automator() internal view returns (IAutomator) {
        return IAutomator(_getAddress(_addressKey(Addresses.AUTOMATOR)));
    }

    function _dopplerLocker() internal view returns (IDopplerLocker) {
        return IDopplerLocker(_getAddress(_addressKey(Addresses.DOPPLER_LOCKER)));
    }

    function _transferLocker() internal view returns (ITransferLocker) {
        return ITransferLocker(_getAddress(_addressKey(Addresses.TRANSFER_LOCKER)));
    }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControl, CreReceiver) returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || AccessControl.supportsInterface(interfaceId)
            || CreReceiver.supportsInterface(interfaceId);
    }

    // --------------------------------------------
    //  Internal — staleness GC / score sync
    // --------------------------------------------

    /**
     * @dev If `deactivatedAt` is set and at least `STALE_AFTER` old, purge the row.
     *      Returns true when the slot was purged (caller must not advance `i`).
     */
    function _purgeIfStale(uint256 index) private returns (bool purged) {
        MinutesStore storage store = _minutesStore[_playerIds[index]];
        uint64 deactivatedAt = store.deactivatedAt;
        if (deactivatedAt == 0) return false;
        if (block.timestamp < uint256(deactivatedAt) + STALE_AFTER) return false;
        _purgePlayerAt(index);
        return true;
    }

    /// @dev Idle-decay one player's `currentLeagueId` score to that league's `G_now`.
    function _syncPlayerScore(bytes32 playerId, FinalRoundCache memory frCache) private {
        MinutesStore storage store = _minutesStore[playerId];
        bytes32 leagueId = store.currentLeagueId;
        if (leagueId == bytes32(0)) return;

        uint256 lmIndex = _leagueMinutesIndex(store, leagueId);
        if (lmIndex == type(uint256).max) return;

        LeagueMinutes storage lm = store.leagueMinutes[lmIndex];
        uint32 last = lm.lastScoreGlobalRound;
        if (last == 0 || lm.weightedScoreWad == 0) return;

        uint32 gNow = _globalRoundNow(leagueId, frCache);
        if (gNow <= last) return;

        _syncLeagueScoreToNow(lm, gNow);
        emit Events.WeightedScoreUpdated(playerId, leagueId, lm.weightedScoreWad);
    }

    // --------------------------------------------
    //  Internal — classify
    // --------------------------------------------

    /**
     * @dev Deployed → continuity lifecycle; undeployed → deploy cohort (or none).
     *      Score = `currentLeagueId` row. New-to-league tenure uses `thresholdNewTransfer`.
     */
    function _classify(
        bytes32 playerId,
        IPlayerSetRegistry registry
    ) private view returns (VerifyAction action, uint32 effectiveMins) {
        if (registry.playerExists(playerId)) {
            PlayerStatus status = registry.getPlayerSet(playerId).status;
            bool stillActive;
            (stillActive, effectiveMins) = _evaluateContinuity(playerId);

            if (status == PlayerStatus.INACTIVE) {
                if (stillActive) return (VerifyAction.Reactivate, effectiveMins);
                return (VerifyAction.None, 0);
            }
            if (!stillActive) return (VerifyAction.Deactivate, effectiveMins);
            return (VerifyAction.None, 0);
        }

        (bool eligible, EligibilityBucket bucket, uint32 mins) = _evaluateForDeploy(playerId);
        if (!eligible) return (VerifyAction.None, 0);
        effectiveMins = mins;

        if (bucket == EligibilityBucket.Goalkeeper) return (VerifyAction.DeployGoalkeeper, mins);
        if (bucket == EligibilityBucket.Under21) return (VerifyAction.DeployUnder21, mins);
        if (bucket == EligibilityBucket.Outfield) return (VerifyAction.DeployOutfield, mins);
        if (bucket == EligibilityBucket.NewTransfer) return (VerifyAction.DeployNewTransfer, mins);
        return (VerifyAction.None, 0);
    }

    /**
     * @dev Deploy path. Uses stored `LeagueMinutes` for `currentLeagueId` (fresh after sync).
     *      missing DOB / no club → false;
     *      `startYearCurrentLeague ==` current league season → `thresholdNewTransfer`;
     *      else continuity gates.
     */
    function _evaluateForDeploy(bytes32 playerId)
        private
        view
        returns (bool eligible, EligibilityBucket bucket, uint32 effectiveMins)
    {
        MinutesStore storage store = _minutesStore[playerId];
        if (store.birthDate == 0 || store.currentClubId == bytes32(0) || store.currentLeagueId == bytes32(0)) {
            return (false, EligibilityBucket.None, 0);
        }

        effectiveMins = _effectiveMins(store);

        if (_isNewToCurrentLeague(store)) {
            bucket = EligibilityBucket.NewTransfer;
            eligible = effectiveMins >= thresholdNewTransfer;
            return (eligible, bucket, effectiveMins);
        }

        (eligible, bucket) = _continuityGate(store, effectiveMins);
    }

    /**
     * @dev Continuity for deployed markets.
     *      Post cross-league move (`startYearCurrentLeague ==` current season): 1-min bar
     *      (`thresholdNewTransfer`) so e.g. Haaland→Madrid reactivates after first appearance.
     *      Otherwise GK / u21 / outfield thresholds.
     */
    function _evaluateContinuity(bytes32 playerId) private view returns (bool stillActive, uint32 effectiveMins) {
        MinutesStore storage store = _minutesStore[playerId];
        if (store.birthDate == 0) {
            return (false, 0);
        }

        effectiveMins = _effectiveMins(store);

        if (_isNewToCurrentLeague(store)) {
            stillActive = effectiveMins >= thresholdNewTransfer;
            return (stillActive, effectiveMins);
        }

        (stillActive,) = _continuityGate(store, effectiveMins);
    }

    /// @dev True when this league tenure started in the league's live season year.
    function _isNewToCurrentLeague(MinutesStore storage store) private view returns (bool) {
        uint16 startYear = store.startYearCurrentLeague;
        if (startYear == 0 || store.currentLeagueId == bytes32(0)) return false;
        return startYear == _currentSeasonYear(store.currentLeagueId);
    }

    /// @dev Shared GK / u21 / outfield threshold gate (live `EligibilityCriteria` storage).
    function _continuityGate(
        MinutesStore storage store,
        uint32 effectiveMins
    ) private view returns (bool ok, EligibilityBucket bucket) {
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

    /// @dev Effective minutes from `currentLeagueId` score (0 if no row / no league).
    function _effectiveMins(MinutesStore storage store) private view returns (uint32) {
        bytes32 leagueId = store.currentLeagueId;
        if (leagueId == bytes32(0)) return 0;
        uint256 lmIndex = _leagueMinutesIndex(store, leagueId);
        if (lmIndex == type(uint256).max) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(store.leagueMinutes[lmIndex].weightedScoreWad / SCORE_WAD);
    }

    /// @dev Live season year for `leagueId` (treasury cursors; fallback to workflow year).
    function _currentSeasonYear(bytes32 leagueId) private view returns (uint16) {
        address treasury = _tournamentRegistry().getPbrTreasury(leagueId);
        if (treasury == address(0)) return _control.currentSeasonStartYear;
        (uint16 season,,) = IPbrTreasury(treasury).getCursors();
        return season == 0 ? _control.currentSeasonStartYear : season;
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
     * @dev Drain SORT pending arrays:
     *      - `_pendingLeftLeague` → TransferLocker `LeftLeague` (deployed only)
     *      - `_pendingLeagueChanged` → TransferLocker `ChangedLeague` (deployed only)
     *      - `_pendingClubChanged` → clear only (events already emitted on SORT)
     */
    function _drainChangers() private {
        IPlayerSetRegistry registry = _playerSetRegistry();

        _enqueueDeployedPending(_takePendingLeftLeague(), LifecycleReason.LeftLeague, registry);
        _enqueueDeployedPending(_takePendingLeagueChanged(), LifecycleReason.ChangedLeague, registry);
        // Club moves: membership already updated on SORT; drop the staging array.
        _takePendingClubChanged();
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
        _automator()
            .executeAutomation(
                address(_dopplerLocker()), 0, abi.encodeWithSelector(IDopplerLocker.enqueueEligible.selector, groups)
            );
    }

    function _enqueueLifecycle(bytes32[] memory ids, LifecycleReason reason, uint32[] memory effectiveMins) private {
        _automator()
            .executeAutomation(
                address(_transferLocker()),
                0,
                abi.encodeWithSelector(ITransferLocker.enqueueLifecycle.selector, ids, reason, effectiveMins)
            );
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
