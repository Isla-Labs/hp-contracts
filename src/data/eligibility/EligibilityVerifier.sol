// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { AddressBook } from "@base/abstract/AddressBook.sol";
import { CreReceiver } from "@base/abstract/CreReceiver.sol";
import { RateLimit } from "@base/abstract/RateLimit.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";

import { IAutomator } from "@interfaces/governance/IAutomator.sol";
import { IDopplerLocker } from "@interfaces/governance/IDopplerLocker.sol";
import { ITransferLocker } from "@interfaces/governance/ITransferLocker.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { LifecycleReason } from "@types/governance/LifecycleTypes.sol";
import { PlayerStatus, Position } from "@base/global/types/PlayerSetTypes.sol";

import { EligibilityCriteria } from "@data/eligibility/base/EligibilityCriteria.sol";
import { EligibilityStore } from "@data/eligibility/base/EligibilityStore.sol";

import { EligibilityErrors as Errors } from "@errors/data/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@events/data/EligibilityEvents.sol";
import {
    EligibilityBucket,
    EligibilityGroups,
    MinutesStore,
    SCORE_WAD
} from "@types/data/EligibilityTypes.sol";

/**
 * @title EligibilityVerifier
 * @notice Rate-limited eligibility runner over `EligibilityStore` minutes / squad state.
 * @dev Deploy behind `TransparentUpgradeableProxy`. Waiting-room writes go through `Automator`
 *      (caller→target routes). Scores are maintained in `recordAppearances`; verify only decays
 *      to `G_now` then classifies. See `README.md` for formula and thresholds.
 *      Protocol addresses are resolved once from `AddressProvider` at `initialize`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract EligibilityVerifier is Initializable, AddressBook, EligibilityStore, EligibilityCriteria, RateLimit {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    /// @notice Cat-3 relay for waiting-room enqueue (must have routes to lockers).
    IAutomator public automator;
    /// @notice Waiting-room receiver for soft-inactivity / league-leave / reactivate.
    ITransferLocker public transferLocker;
    /// @notice Waiting-room receiver for eligible deploy cohorts (enqueued via Automator).
    IDopplerLocker public dopplerLocker;

    /// @dev Per-player outcome of the verify scan (after score sync).
    enum VerifyAction {
        None,
        DeployGoalkeeper,
        DeployUnder21,
        DeployOutfield,
        DeployNewTransfer,
        Deactivate,
        Reactivate
    }

    // --------------------------------------------
    //  Construction / initialization
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @param cooldown_ Global cooldown for `verifyEligibility` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_, uint256 cooldown_) AddressBook(addressProvider_) RateLimit(cooldown_) {
        _disableInitializers();
    }

    /**
     * @notice Initialize proxy storage (call via `TransparentUpgradeableProxy` constructor data).
     * @dev Resolves DAO / timelock / registries / lockers / CRE forwarder / PPM verifier from
     *      `AddressProvider` once into storage; only league-specific params are explicit.
     * @param expectedWorkflowId_ Squad-fill CRE workflow id (required; non-zero).
     * @param leagueId_ Domestic-league tournament id (score filter + clock source).
     * @param baseYear_ G-index origin season start year.
     */
    function initialize(
        bytes32 expectedWorkflowId_,
        bytes32 leagueId_,
        uint16 baseYear_
    ) external initializer {
        if (expectedWorkflowId_ == bytes32(0)) revert Errors.ZeroWorkflowId();
        if (leagueId_ == bytes32(0) || baseYear_ == 0) revert Errors.ZeroId();

        address constitutionalTimelock_ = _getAddress(_addressKey(Addresses.CONSTITUTIONAL_TIMELOCK));
        address dao_ = _getAddress(_addressKey(Addresses.DAO));
        address forwarder_ = _getAddress(_addressKey(Addresses.CRE_FORWARDER));
        address playerSetRegistry_ = _getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY));
        address tournamentRegistry_ = _getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY));
        address ppmVerifier_ = _getAddress(_addressKey(Addresses.PPM_VERIFIER));
        address automator_ = _getAddress(_addressKey(Addresses.AUTOMATOR));
        address dopplerLocker_ = _getAddress(_addressKey(Addresses.DOPPLER_LOCKER));
        address transferLocker_ = _getAddress(_addressKey(Addresses.TRANSFER_LOCKER));

        __EligibilityCriteria_init(constitutionalTimelock_, dao_);
        __CreReceiver_init(forwarder_);
        _setExpectedWorkflowId(expectedWorkflowId_);

        ppmVerifier = ppmVerifier_;
        playerSetRegistry = IPlayerSetRegistry(playerSetRegistry_);
        tournamentRegistry = ITournamentRegistry(tournamentRegistry_);
        automator = IAutomator(automator_);
        dopplerLocker = IDopplerLocker(dopplerLocker_);
        transferLocker = ITransferLocker(transferLocker_);
        leagueId = leagueId_;
        baseYear = baseYear_;
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc CreReceiver
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl, CreReceiver) returns (bool) {
        return AccessControl.supportsInterface(interfaceId) || CreReceiver.supportsInterface(interfaceId);
    }

    // --------------------------------------------
    //  Eligibility (offchain runner)
    // --------------------------------------------

    /**
     * @notice Decay page scores to `G_now`; enqueue eligibles / lifecycle candidates.
     * @dev Public (anyone may run the page). Score mass is updated in `recordAppearances`;
     *      this call only applies idle decay, then classifies.
     *      1) Decay each page player's `weightedScoreWad` from `lastScoreGlobalRound` → `G_now`
     *      2) Classify once → deploy cohorts / lifecycle sets (page-sized buffers, then compact)
     *      3) Automator → lockers (also drains CRE-staged `_pendingLeftLeague` as `LeftLeague`)
     *      Continuity uses GK/u21/outfield thresholds only (not the newTransfer ≥ 1 shortcut).
     */
    function verifyEligibility(
        uint256 offset,
        uint256 limit
    ) external rateLimited returns (EligibilityGroups memory groups) {
        // CRE league-leavers are independent of the score page — drain whenever anyone scans.
        _drainPendingLeftLeague();

        uint256 total = _playerIds.length;
        if (offset >= total || limit == 0) {
            return groups;
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

        FinalRoundCache memory frCache;
        uint16 currentSeasonYear = _currentSeasonYear();
        _syncPageScores(offset, end, limit, frCache);

        uint256 page = end - offset;
        bytes32[] memory gk = new bytes32[](page);
        bytes32[] memory u21 = new bytes32[](page);
        bytes32[] memory outf = new bytes32[](page);
        bytes32[] memory nt = new bytes32[](page);
        bytes32[] memory deact = new bytes32[](page);
        bytes32[] memory react = new bytes32[](page);
        uint32[] memory deactMinsBuf = new uint32[](page);
        uint32[] memory reactMinsBuf = new uint32[](page);

        uint256 gkN;
        uint256 u21N;
        uint256 outN;
        uint256 ntN;
        uint256 deactN;
        uint256 reactN;

        for (uint256 i = offset; i < end; ++i) {
            bytes32 playerId = _playerIds[i];
            (VerifyAction action, uint32 effectiveMins) = _classify(playerId, currentSeasonYear);

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
        }

        groups.goalkeepers = _compactIds(gk, gkN);
        groups.under21 = _compactIds(u21, u21N);
        groups.outfield = _compactIds(outf, outN);
        groups.newTransfers = _compactIds(nt, ntN);
        groups.toDeactivate = _compactIds(deact, deactN);
        groups.toReactivate = _compactIds(react, reactN);

        if (gkN + u21N + outN + ntN != 0) {
            automator.executeAutomation(
                address(dopplerLocker), 0, abi.encodeCall(IDopplerLocker.enqueueEligible, (groups))
            );
        }
        if (deactN != 0) {
            _enqueueLifecycle(
                groups.toDeactivate, LifecycleReason.ContinuityUnderThreshold, _compactMins(deactMinsBuf, deactN)
            );
        }
        if (reactN != 0) {
            _enqueueLifecycle(groups.toReactivate, LifecycleReason.Reactivate, _compactMins(reactMinsBuf, reactN));
        }
    }

    // --------------------------------------------
    //  Internal — eligibility
    // --------------------------------------------

    /// @dev CRE-staged leavers → TransferLocker (`LeftLeague`), via Automator.
    function _drainPendingLeftLeague() private {
        bytes32[] memory ids = _takePendingLeftLeague();
        if (ids.length == 0) return;
        _enqueueLifecycle(ids, LifecycleReason.LeftLeague, new uint32[](0));
    }

    /// @dev Relay lifecycle enqueue through Automator (route: this → transferLocker).
    function _enqueueLifecycle(
        bytes32[] memory ids,
        LifecycleReason reason,
        uint32[] memory effectiveMins
    ) private {
        automator.executeAutomation(
            address(transferLocker),
            0,
            abi.encodeCall(ITransferLocker.enqueueLifecycle, (ids, reason, effectiveMins))
        );
    }

    /// @dev Pass 0: idle-decay score sync for `[offset, end)` to `G_now` (skips no-op players).
    function _syncPageScores(uint256 offset, uint256 end, uint256 limit, FinalRoundCache memory frCache) private {
        uint32 gNow = _globalRoundNow(frCache);
        uint256 synced;
        for (uint256 i = offset; i < end; ++i) {
            bytes32 playerId = _playerIds[i];
            MinutesStore storage store = _minutesStore[playerId];
            uint32 last = store.lastScoreGlobalRound;
            if (last == 0 || store.weightedScoreWad == 0 || gNow <= last) continue;

            _syncScoreToNow(store, gNow);
            unchecked {
                ++synced;
            }
            emit Events.WeightedScoreUpdated(playerId, store.weightedScoreWad);
        }
        emit Events.WeightedScoresSynced(offset, limit, synced, gNow);
    }

    /**
     * @dev Deployed → continuity lifecycle; undeployed → deploy cohort (or none).
     *      Continuity ignores the newTransfer shortcut.
     */
    function _classify(
        bytes32 playerId,
        uint16 currentSeasonYear
    ) private view returns (VerifyAction action, uint32 effectiveMins) {
        if (playerSetRegistry.playerExists(playerId)) {
            PlayerStatus status = playerSetRegistry.getPlayerSet(playerId).status;
            bool stillActive;
            (stillActive, effectiveMins) = _evaluateContinuity(playerId);

            if (status == PlayerStatus.INACTIVE) {
                if (stillActive) return (VerifyAction.Reactivate, effectiveMins);
                return (VerifyAction.None, 0);
            }
            if (!stillActive) return (VerifyAction.Deactivate, effectiveMins);
            return (VerifyAction.None, 0);
        }

        (bool eligible, EligibilityBucket bucket, uint32 mins) = _evaluateForDeploy(playerId, currentSeasonYear);
        if (!eligible) return (VerifyAction.None, 0);
        effectiveMins = mins;

        if (bucket == EligibilityBucket.Goalkeeper) return (VerifyAction.DeployGoalkeeper, mins);
        if (bucket == EligibilityBucket.Under21) return (VerifyAction.DeployUnder21, mins);
        if (bucket == EligibilityBucket.Outfield) return (VerifyAction.DeployOutfield, mins);
        if (bucket == EligibilityBucket.NewTransfer) return (VerifyAction.DeployNewTransfer, mins);
        return (VerifyAction.None, 0);
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


    /**
     * @dev Deploy path. Uses stored `weightedScoreWad` (fresh after pass 0 decay).
     *      missing DOB → false;
     *      newTransfer/backFromLoan (earliestSeasonStartYear == current) → `thresholdNewTransfer`;
     *      else continuity gates (`thresholdGk` / `thresholdUnder21` / `thresholdOutfield`).
     */
    function _evaluateForDeploy(
        bytes32 playerId,
        uint16 currentSeasonYear
    ) private view returns (bool eligible, EligibilityBucket bucket, uint32 effectiveMins) {
        MinutesStore storage store = _minutesStore[playerId];
        if (store.birthDate == 0) {
            return (false, EligibilityBucket.None, 0);
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        effectiveMins = uint32(store.weightedScoreWad / SCORE_WAD);

        // DeployDoppler flag: newTransfer / backFromLoan for the current season.
        if (store.earliestSeasonStartYear == currentSeasonYear) {
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
    function _evaluateContinuity(bytes32 playerId) private view returns (bool stillActive, uint32 effectiveMins) {
        MinutesStore storage store = _minutesStore[playerId];
        if (store.birthDate == 0) {
            return (false, 0);
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        effectiveMins = uint32(store.weightedScoreWad / SCORE_WAD);
        (stillActive,) = _continuityGate(store, effectiveMins);
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

    /// @dev Whole years since unix DOB; leap years are ignored (same spirit as a simple day-count age).
    function _ageYears(uint256 birthDate) private view returns (uint256) {
        if (birthDate == 0 || birthDate >= block.timestamp) return 0;
        return (block.timestamp - birthDate) / 365 days;
    }
}
