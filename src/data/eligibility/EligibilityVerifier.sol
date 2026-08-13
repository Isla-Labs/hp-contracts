// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { RateLimit } from "@base/abstract/RateLimit.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { EligibilityErrors as Errors } from "@errors/data/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@events/data/EligibilityEvents.sol";
import { IEligibilityVerifier } from "@interfaces/data/IEligibilityVerifier.sol";
import { ISquadStore } from "@interfaces/data/ISquadStore.sol";
import { IOrchestrator } from "@interfaces/IOrchestrator.sol";
import { IPlayerSetRegistry } from "@interfaces/registries/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@interfaces/registries/ITournamentRegistry.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";
import { EligibilityCriteria } from "@src/data/eligibility/base/EligibilityCriteria.sol";
import { VerifyAction } from "@types/data/EligibilityTypes.sol";
import { SCORE_WAD, MinutesStore, SquadList, VerifySnapshot } from "@types/data/SquadStoreTypes.sol";
import { LifecycleReason } from "@types/initializers/LifecycleTypes.sol";
import { EligibilityBucket, EligibilityGroups } from "@types/initializers/DopplerTypes.sol";
import { PlayerStatus, Position } from "@types/registries/PlayerSetTypes.sol";

/**
 * @title EligibilityVerifier
 * @notice Criteria + rate-limited verify scan; Orchestrator queuePlayers / enqueueLifecycle handoff.
 * @dev Separation:
 *        - `SquadStore` — bootstrap/`refreshSquads` + `recordAppearances` / score math
 *        - `EligibilityCriteria` — governance thresholds
 *        - this contract — scan, classify; deploy + lifecycle intake via Orchestrator (deployer)
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract EligibilityVerifier is AddressBook, EligibilityCriteria, RateLimit, IEligibilityVerifier {
    uint256 public constant DEFAULT_COOLDOWN = 1 hours;

    modifier onlyTimelock() {
        if (msg.sender != _getAddress(_addressKey(Addresses.TIMELOCK))) revert Errors.Unauthorized();
        _;
    }

    /**
     * @param addressProvider_ Canonical `AddressProvider`.
     * @dev Base Sepolia (84532): `1 minutes`. Else: `cooldown_ == 0` → `DEFAULT_COOLDOWN`.
     */
    constructor(address addressProvider_)
        AddressBook(addressProvider_)
        RateLimit(block.chainid == 84_532 ? 1 minutes : DEFAULT_COOLDOWN)
    {
        __EligibilityCriteria_init();
    }

    // --------------------------------------------
    //  Governance — thresholds
    // --------------------------------------------

    function setEligibilityThresholds(
        uint32 thresholdGk_,
        uint32 thresholdUnder21_,
        uint32 thresholdOutfield_,
        uint32 thresholdNewTransfer_,
        uint256 under21Age_
    ) external onlyTimelock {
        _setEligibilityThresholds(
            thresholdGk_, thresholdUnder21_, thresholdOutfield_, thresholdNewTransfer_, under21Age_
        );
    }

    // --------------------------------------------
    //  Eligibility scan
    // --------------------------------------------

    /// @inheritdoc IEligibilityVerifier
    function verifyEligibility(
        uint256 offset,
        uint256 limit
    ) external rateLimited returns (EligibilityGroups memory groups) {
        ISquadStore s = _squadStore();
        uint256 total = s.playerCount();
        if (offset >= total || limit == 0) {
            _drainChangers();
            return groups;
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

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
    //  Views — thin SquadStore forwards
    // --------------------------------------------

    /// @inheritdoc IEligibilityVerifier
    function playerCount() external view returns (uint256) {
        return _squadStore().playerCount();
    }

    /// @inheritdoc IEligibilityVerifier
    function playerIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        return _squadStore().playerIds(offset, limit);
    }

    /// @inheritdoc IEligibilityVerifier
    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory) {
        return _squadStore().getMinutesStore(playerId);
    }

    /// @inheritdoc IEligibilityVerifier
    function getVerifySnapshot(bytes32 playerId) external view returns (VerifySnapshot memory) {
        return _squadStore().getVerifySnapshot(playerId);
    }

    /// @inheritdoc IEligibilityVerifier
    function getSquadList(bytes32 clubId) external view returns (SquadList memory) {
        return _squadStore().getSquadList(clubId);
    }

    // --------------------------------------------
    //  AddressBook hooks
    // --------------------------------------------

    function _squadStore() private view returns (ISquadStore) {
        return ISquadStore(_getAddress(_addressKey(Addresses.SQUAD_STORE)));
    }

    function _playerSetRegistry() private view returns (IPlayerSetRegistry) {
        return IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));
    }

    function _tournamentRegistry() private view returns (ITournamentRegistry) {
        return ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }

    function _orchestrator() private view returns (IOrchestrator) {
        return IOrchestrator(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));
    }

    // --------------------------------------------
    //  Internal — classify
    // --------------------------------------------

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

    function _isNewToCurrentLeague(VerifySnapshot memory snap) private view returns (bool) {
        uint16 startYear = snap.startYearCurrentLeague;
        if (startYear == 0 || snap.currentLeagueId == bytes32(0)) return false;
        return startYear == _currentSeasonYear(snap.currentLeagueId);
    }

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

    function _effectiveMins(VerifySnapshot memory snap) private pure returns (uint32) {
        if (snap.currentLeagueId == bytes32(0) || snap.currentLeague.leagueId == bytes32(0)) return 0;
        return uint32(snap.currentLeague.weightedScoreWad / SCORE_WAD);
    }

    function _currentSeasonYear(bytes32 leagueId) private view returns (uint16) {
        address treasury = _tournamentRegistry().getPbrTreasury(leagueId);
        if (treasury == address(0)) {
            // Fallback: latest squad/round bootstrap season.
            return _squadStore().getLatestSeason(leagueId).seasonStartYear;
        }
        (uint16 season,,) = IPbrTreasury(treasury).getCursors();
        if (season == 0) return _squadStore().getLatestSeason(leagueId).seasonStartYear;
        return season;
    }

    function _ageYears(uint256 birthDate) private view returns (uint256) {
        if (birthDate == 0 || birthDate >= block.timestamp) return 0;
        return (block.timestamp - birthDate) / 365 days;
    }

    // --------------------------------------------
    //  Internal — SORT change buckets → TransferLocker
    // --------------------------------------------

    function _drainChangers() private {
        ISquadStore s = _squadStore();
        IPlayerSetRegistry registry = _playerSetRegistry();

        _enqueueDeployedPending(s.takePendingLeftLeague(), LifecycleReason.LeftLeague, registry);
        _enqueueDeployedPending(s.takePendingLeagueChanged(), LifecycleReason.ChangedLeague, registry);
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

    /**
     * @dev Flatten deploy cohorts and `Orchestrator.queuePlayers` per `currentLeagueId` + latest season.
     * @dev This contract must hold Orchestrator `MARKET_DEPLOYER_ROLE`.
     */
    function _enqueueEligible(EligibilityGroups memory groups) private {
        ISquadStore s = _squadStore();
        IOrchestrator orch = _orchestrator();

        _queueDeployBucket(s, orch, groups.goalkeepers);
        _queueDeployBucket(s, orch, groups.under21);
        _queueDeployBucket(s, orch, groups.outfield);
        _queueDeployBucket(s, orch, groups.newTransfers);
    }

    function _queueDeployBucket(ISquadStore s, IOrchestrator orch, bytes32[] memory playerIds_) private {
        uint256 n = playerIds_.length;
        if (n == 0) return;

        // Group by league (page sizes are small — O(n²) is fine).
        for (uint256 i; i < n; ++i) {
            bytes32 playerId = playerIds_[i];
            if (playerId == bytes32(0)) continue;
            bytes32 leagueId = s.getMinutesStore(playerId).currentLeagueId;
            if (leagueId == bytes32(0)) continue;

            uint256 count = 1;
            for (uint256 j = i + 1; j < n; ++j) {
                if (playerIds_[j] == bytes32(0)) continue;
                if (s.getMinutesStore(playerIds_[j]).currentLeagueId == leagueId) {
                    unchecked {
                        ++count;
                    }
                }
            }

            bytes32[] memory batch = new bytes32[](count);
            uint256 k;
            batch[k] = playerId;
            unchecked {
                ++k;
            }
            playerIds_[i] = bytes32(0);
            for (uint256 j = i + 1; j < n; ++j) {
                if (playerIds_[j] == bytes32(0)) continue;
                if (s.getMinutesStore(playerIds_[j]).currentLeagueId != leagueId) continue;
                batch[k] = playerIds_[j];
                playerIds_[j] = bytes32(0);
                unchecked {
                    ++k;
                }
            }

            bytes32 seasonId = s.getLatestSeason(leagueId).seasonId;
            orch.queueAssets(leagueId, seasonId, batch);
        }
    }

    function _enqueueLifecycle(bytes32[] memory ids, LifecycleReason reason, uint32[] memory effectiveMins) private {
        _orchestrator().queueChanges(ids, reason, effectiveMins);
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
