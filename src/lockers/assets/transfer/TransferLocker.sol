// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { Oracle } from "@base/abstract/Oracle.sol";
import { RateLimit } from "@base/abstract/RateLimit.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { LifecycleErrors as Errors } from "@errors/lockers/LifecycleErrors.sol";
import { LifecycleEvents as Events } from "@events/lockers/LifecycleEvents.sol";
import { IOrchestrator } from "@interfaces/IOrchestrator.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { ITransferLocker } from "@interfaces/governance/ITransferLocker.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";
import { LifecycleQueueStatus, LifecycleReason, PendingLifecycle } from "@types/lockers/LifecycleTypes.sol";
import { PlayerSet, PlayerStatus } from "@types/registries/PlayerSetTypes.sol";
import { AddressProvider } from "@src/AddressProvider.sol";

/// @dev Minimal FeeRouter surface for hub consistency checks (no markets import).
interface IFeeRouterHub {
    function pbrFeeHub() external view returns (address);
}

/**
 * @title TransferLocker
 * @notice Waiting room for soft-inactivity / reactivation / cross-league transfer (mirrors DopplerLocker).
 * @dev Flow:
 *      0) Orchestrator or AddressBook `ELIGIBILITY_VERIFIER` enqueues via `enqueueLifecycle`.
 *      1) 24h review window (`queueWait`); Orchestrator may `unqueueAsset`.
 *      2) Anyone calls `processLifecycle` after wait (rate-limited):
 *           - ContinuityUnderThreshold / LeftLeague → `deactivate()`
 *           - ChangedLeague / Reactivate → `CvmJob.LeagueTransfer` → fulfill →
 *             `setLeagueId` (+ Reactivate: `reactivate()` — status from `activePool` hooks)
 *
 *      Immutable singleton: registries / Orchestrator resolve via AddressBook at call time.
 *      Registry writes relay through `Orchestrator.execute` (this contract must hold
 *      `AUTHORIZED_CONTRACT`).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TransferLocker is AddressBook, Oracle, RateLimit, ITransferLocker {
    // --------------------------------------------
    //  Constants
    // --------------------------------------------

    uint256 public constant DEFAULT_QUEUE_WAIT = 24 hours;
    uint256 public constant DEFAULT_PROCESS_COOLDOWN = 5 minutes;

    // --------------------------------------------
    //  Config
    // --------------------------------------------

    /// @notice Seconds after `Queued` before `processLifecycle` may finalize.
    uint256 public queueWait;

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    PendingLifecycle[] private _pending;
    /// @dev ContinuityUnderThreshold / LeftLeague / ChangedLeague — pending review.
    mapping(bytes32 playerId => bool) private _queuedDeactivate;
    /// @dev Reactivate — pending restore-from-INACTIVE review.
    mapping(bytes32 playerId => bool) private _queuedReactivate;
    mapping(bytes32 requestId => bytes32 playerId) private _oraclePlayerId;

    // --------------------------------------------
    //  Access Control
    // --------------------------------------------

    modifier onlyTimelock() {
        if (msg.sender != _getAddress(_addressKey(Addresses.TIMELOCK))) revert Errors.Unauthorized();
        _;
    }

    modifier onlyOrchestrator() {
        if (msg.sender != _getAddress(_addressKey(Addresses.ORCHESTRATOR))) revert Errors.Unauthorized();
        _;
    }

    /// @dev Orchestrator always; `ELIGIBILITY_VERIFIER` when registered on AddressProvider.
    modifier onlyEnqueueWriter() {
        if (!_isEnqueueWriter(msg.sender)) revert Errors.Unauthorized();
        _;
    }

    // --------------------------------------------
    //  Construction
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider`.
    /// @dev `CVM_ROUTER` must already be registered on AddressProvider (oracle set first).
    constructor(address addressProvider_)
        AddressBook(addressProvider_)
        Oracle(_cvmRouter(addressProvider_))
        RateLimit(DEFAULT_PROCESS_COOLDOWN)
    {
        if (addressProvider_ == address(0)) revert Errors.ZeroAddress();
        queueWait = DEFAULT_QUEUE_WAIT;
    }

    function _cvmRouter(address addressProvider_) private view returns (address router) {
        router = AddressProvider(payable(addressProvider_)).get(keccak256(bytes(Addresses.CVM_ROUTER)));
        if (router == address(0)) revert Errors.ZeroAddress();
    }

    // --------------------------------------------
    //  AddressBook resolvers
    // --------------------------------------------

    function _playerSetRegistry() private view returns (IPlayerSetRegistry) {
        return IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));
    }

    function _tournamentRegistry() private view returns (ITournamentRegistry) {
        return ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }

    function _isEnqueueWriter(address sender) private view returns (bool) {
        if (sender == _getAddress(_addressKey(Addresses.ORCHESTRATOR))) return true;
        // Soft: verifier may be unset until the data plane is wired.
        address verifier = addressProvider.get(_addressKey(Addresses.ELIGIBILITY_VERIFIER));
        return verifier != address(0) && sender == verifier;
    }

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    /// @inheritdoc ITransferLocker
    function setQueueWait(uint256 queueWait_) external onlyTimelock {
        if (queueWait_ == 0) revert Errors.NotConfigured();
        uint256 previous = queueWait;
        queueWait = queueWait_;
        emit Events.QueueWaitUpdated(previous, queueWait_);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc ITransferLocker
    function pendingCount() external view returns (uint256) {
        return _pending.length;
    }

    /// @inheritdoc ITransferLocker
    function isQueued(bytes32 playerId) external view returns (bool) {
        return _queuedDeactivate[playerId] || _queuedReactivate[playerId];
    }

    /// @inheritdoc ITransferLocker
    function isQueuedFor(bytes32 playerId, LifecycleReason reason) external view returns (bool) {
        if (reason == LifecycleReason.Reactivate) return _queuedReactivate[playerId];
        return _queuedDeactivate[playerId];
    }

    /// @inheritdoc ITransferLocker
    function pendingLifecycle(uint256 offset, uint256 limit) external view returns (PendingLifecycle[] memory out) {
        uint256 total = _pending.length;
        if (offset >= total || limit == 0) {
            return new PendingLifecycle[](0);
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

        uint256 n = end - offset;
        out = new PendingLifecycle[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = _pending[offset + i];
        }
    }

    /// @inheritdoc ITransferLocker
    function requireFeeTopologyConsistent(bytes32 playerId) external view {
        _requireFeeTopologyConsistent(playerId);
    }

    // --------------------------------------------
    //  Queue start
    // --------------------------------------------

    /// @inheritdoc ITransferLocker
    function enqueueLifecycle(
        bytes32[] calldata playerIds,
        LifecycleReason reason,
        uint32[] calldata effectiveMins
    ) external onlyEnqueueWriter {
        uint256 length = playerIds.length;
        if (effectiveMins.length != 0 && effectiveMins.length != length) {
            revert Errors.LengthMismatch(length, effectiveMins.length);
        }

        bool isReactivate = reason == LifecycleReason.Reactivate;
        uint64 now_ = uint64(block.timestamp);
        uint256 added;
        for (uint256 i; i < length; ++i) {
            bytes32 playerId = playerIds[i];
            if (playerId == bytes32(0)) continue;

            if (isReactivate) {
                if (_queuedReactivate[playerId]) continue;
                _queuedReactivate[playerId] = true;
            } else {
                if (_queuedDeactivate[playerId]) continue;
                _queuedDeactivate[playerId] = true;
            }

            uint32 mins = effectiveMins.length == 0 ? 0 : effectiveMins[i];
            _pending.push(
                PendingLifecycle({
                    playerId: playerId,
                    reason: reason,
                    effectiveMins: mins,
                    queuedAt: now_,
                    status: LifecycleQueueStatus.Queued
                })
            );
            unchecked {
                ++added;
            }
        }

        emit Events.LifecyclePlayersEnqueued(reason, added, _pending.length);
    }

    // --------------------------------------------
    //  Queue end / process
    // --------------------------------------------

    /// @inheritdoc ITransferLocker
    function unqueueAsset(bytes32 playerId) external onlyOrchestrator {
        if (playerId == bytes32(0)) revert Errors.ZeroId();
        uint256 index = _findQueuedIndex(playerId);
        if (index == type(uint256).max) revert Errors.NotQueued(playerId);

        PendingLifecycle storage e = _pending[index];
        if (e.status != LifecycleQueueStatus.Queued) {
            revert Errors.BadQueueStatus(playerId, uint8(e.status));
        }

        _removeAt(index);
        emit Events.AssetUnqueued(playerId);
    }

    /// @inheritdoc ITransferLocker
    function processLifecycle() external rateLimited returns (bytes32 requestId) {
        uint256 length = _pending.length;
        uint256 wait_ = queueWait;
        IPlayerSetRegistry psr = _playerSetRegistry();
        for (uint256 i; i < length; ++i) {
            PendingLifecycle storage e = _pending[i];
            if (e.status != LifecycleQueueStatus.Queued) continue;
            if (block.timestamp < uint256(e.queuedAt) + wait_) continue;

            LifecycleReason reason = e.reason;
            bytes32 playerId = e.playerId;

            // Topology remap (transfer) or restore-from-INACTIVE (reactivate): oracle first.
            if (reason == LifecycleReason.ChangedLeague || reason == LifecycleReason.Reactivate) {
                requestId = _sendOracleRequest(CvmJob.LeagueTransfer, abi.encode(playerId));
                _oraclePlayerId[requestId] = playerId;
                e.status = LifecycleQueueStatus.AwaitingLeagueTransfer;
                emit Events.LeagueTransferRequested(requestId, playerId);
                return requestId;
            }

            // ContinuityUnderThreshold / LeftLeague → soft-inactive
            _exec(address(psr), abi.encodeCall(IPlayerSetRegistry.deactivate, (playerId)));
            emit Events.LifecycleApplied(playerId, reason, PlayerStatus.INACTIVE);
            _removeAt(i);
            return bytes32(0);
        }

        revert Errors.NothingReady();
    }

    // --------------------------------------------
    //  Oracle callback
    // --------------------------------------------

    /// @inheritdoc Oracle
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        bytes32 playerId = _oraclePlayerId[requestId];
        if (playerId == bytes32(0)) revert Errors.UnknownOracleRequest(requestId);
        delete _oraclePlayerId[requestId];

        uint256 index = _findAwaitingIndex(playerId);
        if (index == type(uint256).max) revert Errors.NotQueued(playerId);

        emit Events.LeagueTransferFulfilled(requestId, playerId, err);

        if (err.length != 0) {
            _rearmQueued(index);
            return;
        }

        (bytes32 newLeagueId, bytes32[] memory activeTournamentIds) = abi.decode(response, (bytes32, bytes32[]));

        // Validate oracle payload before registry fan-out (hub, tournaments, league in set).
        if (!_tryValidateLeagueTransfer(playerId, newLeagueId, activeTournamentIds)) {
            _rearmQueued(index);
            return;
        }

        LifecycleReason reason = _pending[index].reason;
        IPlayerSetRegistry psr = _playerSetRegistry();

        _exec(
            address(psr), abi.encodeCall(IPlayerSetRegistry.setLeagueId, (playerId, newLeagueId, activeTournamentIds))
        );

        if (reason == LifecycleReason.Reactivate) {
            _exec(address(psr), abi.encodeCall(IPlayerSetRegistry.reactivate, (playerId)));
        }

        PlayerStatus status = psr.getPlayerSet(playerId).status;
        emit Events.LifecycleApplied(playerId, reason, status);
        _removeAt(index);
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    /**
     * @dev Pre-flight for `setLeagueId`: non-zero league + hub, non-empty unique tournament
     *      ids that exist onchain, and `newLeagueId` present in `activeTournamentIds`.
     */
    function _tryValidateLeagueTransfer(
        bytes32 playerId,
        bytes32 newLeagueId,
        bytes32[] memory activeTournamentIds
    ) private view returns (bool) {
        if (newLeagueId == bytes32(0)) return false;

        ITournamentRegistry tr = _tournamentRegistry();
        if (tr.pbrFeeHubOf(newLeagueId) == address(0)) return false;
        if (!tr.tournamentExists(newLeagueId)) return false;

        PlayerSet memory set = _playerSetRegistry().getPlayerSet(playerId);
        if (set.dopplerData.feeRouter == address(0)) return false;

        uint256 n = activeTournamentIds.length;
        if (n == 0) return false;

        bool hasLeague;
        for (uint256 i; i < n; ++i) {
            bytes32 tournamentId = activeTournamentIds[i];
            if (tournamentId == bytes32(0)) return false;
            if (!tr.tournamentExists(tournamentId)) return false;
            if (tr.getPbrTreasury(tournamentId) == address(0)) return false;
            // Domestic league itself, or a cup/continental that lists this league's hub.
            if (!tr.isLeagueLinkedToTournament(tournamentId, newLeagueId)) return false;
            for (uint256 j; j < i; ++j) {
                if (activeTournamentIds[j] == tournamentId) return false;
            }
            if (tournamentId == newLeagueId) hasLeague = true;
        }
        return hasLeague;
    }

    function _rearmQueued(uint256 index) private {
        PendingLifecycle storage e = _pending[index];
        e.status = LifecycleQueueStatus.Queued;
        e.queuedAt = uint64(block.timestamp);
    }

    /// @dev Hub alignment only — live vault registration is not required for claims.
    function _requireFeeTopologyConsistent(bytes32 playerId) internal view {
        PlayerSet memory set = _playerSetRegistry().getPlayerSet(playerId);

        bytes32 leagueId = set.tournamentData.leagueId;
        if (leagueId == bytes32(0)) revert Errors.MissingLeagueId(playerId);

        address expectedHub = _tournamentRegistry().pbrFeeHubOf(leagueId);
        if (expectedHub == address(0)) revert Errors.HubNotRegistered(leagueId);

        address feeRouter = set.dopplerData.feeRouter;
        if (feeRouter == address(0)) revert Errors.MissingFeeRouter(playerId);

        address actualHub = IFeeRouterHub(feeRouter).pbrFeeHub();
        if (actualHub != expectedHub) {
            revert Errors.FeeHubMismatch(playerId, leagueId, expectedHub, actualHub);
        }
    }

    function _findQueuedIndex(bytes32 playerId) private view returns (uint256) {
        uint256 length = _pending.length;
        for (uint256 i; i < length; ++i) {
            if (_pending[i].playerId == playerId && _pending[i].status == LifecycleQueueStatus.Queued) {
                return i;
            }
        }
        return type(uint256).max;
    }

    function _findAwaitingIndex(bytes32 playerId) private view returns (uint256) {
        uint256 length = _pending.length;
        for (uint256 i; i < length; ++i) {
            if (_pending[i].playerId == playerId && _pending[i].status == LifecycleQueueStatus.AwaitingLeagueTransfer) {
                return i;
            }
        }
        return type(uint256).max;
    }

    function _removeAt(uint256 index) private {
        PendingLifecycle memory e = _pending[index];
        if (e.reason == LifecycleReason.Reactivate) {
            _queuedReactivate[e.playerId] = false;
        } else {
            _queuedDeactivate[e.playerId] = false;
        }

        uint256 last = _pending.length - 1;
        if (index != last) {
            _pending[index] = _pending[last];
        }
        _pending.pop();
    }

    function _exec(address target, bytes memory data) private returns (bytes memory) {
        return IOrchestrator(_getAddress(_addressKey(Addresses.ORCHESTRATOR))).execute(target, 0, data);
    }
}
