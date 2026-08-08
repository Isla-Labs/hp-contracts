// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

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
import { DopplerData, PlayerSet, PlayerStatus } from "@types/registries/PlayerSetTypes.sol";
import { AddressProvider } from "@src/AddressProvider.sol";

/// @dev Minimal FeeRouter surface for hub consistency checks (no markets import).
interface IFeeRouterHub {
    function pbrFeeHub() external view returns (address);
}

/**
 * @title TransferLocker
 * @notice Waiting room for soft-inactivity / reactivation / cross-league transfer (mirrors DopplerLocker).
 * @dev Flow:
 *      0) EligibilityVerifier (or Orchestrator) enqueues via `enqueueLifecycle`.
 *      1) 24h review window (`queueWait`); owner may `unqueueAsset`.
 *      2) Anyone calls `processLifecycle` after wait (rate-limited):
 *           - ContinuityUnderThreshold / LeftLeague → `setStatus(INACTIVE)`
 *             (unregisters vaults for live set; clears `leagueId` / `activeTournaments`)
 *           - ChangedLeague / Reactivate → `CvmJob.LeagueTransfer` → fulfill →
 *             `setLeagueId` (+ Reactivate: `setStatus(BONDING|GRADUATED)` from pool hooks)
 *
 *      Registry writes relay through `Orchestrator.execute` (this proxy must hold
 *      `AUTHORIZED_CONTRACT`).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TransferLocker is Initializable, AddressBook, Ownable, Oracle, RateLimit, ITransferLocker {
    // --------------------------------------------
    //  Constants
    // --------------------------------------------

    uint256 public constant DEFAULT_QUEUE_WAIT = 24 hours;
    uint256 public constant DEFAULT_PROCESS_COOLDOWN = 5 minutes;

    // --------------------------------------------
    //  Config
    // --------------------------------------------

    IPlayerSetRegistry public playerSetRegistry;
    ITournamentRegistry public tournamentRegistry;
    IOrchestrator public orchestrator;

    /// @notice Enqueue writer (set once); owner may also enqueue.
    address public eligibilityVerifier;

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
    //  Initialization
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_)
        AddressBook(addressProvider_)
        Ownable(msg.sender)
        Oracle(_cvmRouter(addressProvider_))
        RateLimit(DEFAULT_PROCESS_COOLDOWN)
    {
        if (addressProvider_ == address(0)) revert Errors.ZeroAddress();
        _disableInitializers();
    }

    /**
     * @notice Resolve registries + Orchestrator; ownership → Orchestrator.
     * @dev This proxy must hold `AUTHORIZED_CONTRACT` on Orchestrator for registry relays.
     */
    function initialize() external initializer {
        queueWait = DEFAULT_QUEUE_WAIT;

        address orch = _getAddress(_addressKey(Addresses.ORCHESTRATOR));
        orchestrator = IOrchestrator(orch);
        playerSetRegistry = IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));
        tournamentRegistry = ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));

        _transferOwnership(orch);
    }

    function _cvmRouter(address addressProvider_) private view returns (address router) {
        router = AddressProvider(payable(addressProvider_)).get(keccak256(bytes(Addresses.CVM_ROUTER)));
        if (router == address(0)) revert Errors.ZeroAddress();
    }

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    /// @notice One-time wire: EligibilityVerifier may call `enqueueLifecycle`.
    function setEligibilityVerifier(address eligibilityVerifier_) external onlyOwner {
        if (eligibilityVerifier != address(0)) revert Errors.AlreadySet();
        if (eligibilityVerifier_ == address(0)) revert Errors.ZeroAddress();
        eligibilityVerifier = eligibilityVerifier_;
        emit Events.EligibilityVerifierSet(eligibilityVerifier_);
    }

    /// @inheritdoc ITransferLocker
    function setQueueWait(uint256 queueWait_) external onlyOwner {
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
    ) external {
        if (msg.sender != owner() && msg.sender != eligibilityVerifier) {
            revert Errors.Unauthorized();
        }

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
    function unqueueAsset(bytes32 playerId) external onlyOwner {
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

            // ContinuityUnderThreshold / LeftLeague → soft-inactive / deactivate
            PlayerStatus status = PlayerStatus.INACTIVE;
            _exec(address(playerSetRegistry), abi.encodeCall(IPlayerSetRegistry.setStatus, (playerId, status)));
            emit Events.LifecycleApplied(playerId, reason, status);
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

        _exec(
            address(playerSetRegistry),
            abi.encodeCall(IPlayerSetRegistry.setLeagueId, (playerId, newLeagueId, activeTournamentIds))
        );

        PlayerStatus status = playerSetRegistry.getPlayerSet(playerId).status;
        if (reason == LifecycleReason.Reactivate) {
            status = _resolveReactivateStatus(playerId);
            _exec(address(playerSetRegistry), abi.encodeCall(IPlayerSetRegistry.setStatus, (playerId, status)));
        }

        emit Events.LifecycleApplied(playerId, reason, status);
        _removeAt(index);
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _resolveReactivateStatus(bytes32 playerId) private view returns (PlayerStatus) {
        DopplerData memory d = playerSetRegistry.getDopplerData(playerId);
        address hooks = address(d.activePool.hooks);
        if (hooks == d.hookDoppler) return PlayerStatus.BONDING;
        if (hooks == d.hookMigrator) return PlayerStatus.GRADUATED;
        revert Errors.UnknownMarketPhase(playerId, hooks);
    }

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
        if (tournamentRegistry.pbrFeeHubOf(newLeagueId) == address(0)) return false;
        if (!tournamentRegistry.tournamentExists(newLeagueId)) return false;

        PlayerSet memory set = playerSetRegistry.getPlayerSet(playerId);
        if (set.dopplerData.feeRouter == address(0)) return false;

        uint256 n = activeTournamentIds.length;
        if (n == 0) return false;

        bool hasLeague;
        for (uint256 i; i < n; ++i) {
            bytes32 tournamentId = activeTournamentIds[i];
            if (tournamentId == bytes32(0)) return false;
            if (!tournamentRegistry.tournamentExists(tournamentId)) return false;
            if (tournamentRegistry.getPbrTreasury(tournamentId) == address(0)) return false;
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
        PlayerSet memory set = playerSetRegistry.getPlayerSet(playerId);

        bytes32 leagueId = set.tournamentData.leagueId;
        if (leagueId == bytes32(0)) revert Errors.MissingLeagueId(playerId);

        address expectedHub = tournamentRegistry.pbrFeeHubOf(leagueId);
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
        return orchestrator.execute(target, 0, data);
    }
}
