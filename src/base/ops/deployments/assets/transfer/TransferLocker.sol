// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";

import { LifecycleErrors as Errors } from "@errors/governance/LifecycleErrors.sol";
import { LifecycleEvents as Events } from "@events/governance/LifecycleEvents.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { ITransferLocker } from "@interfaces/governance/ITransferLocker.sol";
import { LifecycleReason, PendingLifecycle } from "@types/governance/LifecycleTypes.sol";
import { PlayerSet } from "@types/PlayerSetTypes.sol";

/// @dev Minimal FeeRouter surface for hub consistency checks (no markets import).
interface IFeeRouterHub {
    function pbrFeeHub() external view returns (address);
}

/**
 * @title TransferLocker
 * @notice Waiting room for soft-inactivity / reactivation candidates (mirrors DopplerLocker).
 * @dev Flow:
 *      0) EligibilityVerifier (or Orchestrator owner) enqueues continuity failures, league-leavers,
 *         cross-league moves (`ChangedLeague`), or reactivations.
 *      1) Offchain / manual review (webhook + email — TBD) confirms or rejects.
 *      2) Confirmed deactivate → owner → `setStatus(INACTIVE)` (not wired yet).
 *      3) Confirmed reactivate → owner → restore prior active status (not wired yet).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TransferLocker is Ownable, ITransferLocker {
    /// @notice Canonical player market index.
    IPlayerSetRegistry public immutable playerSetRegistry;

    /// @notice Domestic hub + tournament treasury topology.
    ITournamentRegistry public immutable tournamentRegistry;

    /// @notice Enqueue writer (set once); owner may also enqueue.
    address public eligibilityVerifier;

    PendingLifecycle[] private _pending;
    /// @dev ContinuityUnderThreshold / LeftLeague / ChangedLeague — pending review.
    mapping(bytes32 playerId => bool) private _queuedDeactivate;
    /// @dev Reactivate — pending restore-from-INACTIVE review.
    mapping(bytes32 playerId => bool) private _queuedReactivate;

    /**
     * @param orchestrator_ `Orchestrator` — Ownable owner.
     * @param playerSetRegistry_ Canonical `PlayerSetRegistry` proxy.
     * @param tournamentRegistry_ Canonical `TournamentRegistry` proxy.
     */
    constructor(address orchestrator_, address playerSetRegistry_, address tournamentRegistry_) Ownable(orchestrator_) {
        if (playerSetRegistry_ == address(0) || tournamentRegistry_ == address(0)) revert Errors.ZeroAddress();
        playerSetRegistry = IPlayerSetRegistry(playerSetRegistry_);
        tournamentRegistry = ITournamentRegistry(tournamentRegistry_);
    }

    /// @notice One-time wire: EligibilityVerifier may call `enqueueLifecycle`.
    function setEligibilityVerifier(address eligibilityVerifier_) external onlyOwner {
        if (eligibilityVerifier != address(0)) revert Errors.AlreadySet();
        if (eligibilityVerifier_ == address(0)) revert Errors.ZeroAddress();
        eligibilityVerifier = eligibilityVerifier_;
        emit Events.EligibilityVerifierSet(eligibilityVerifier_);
    }

    /// @inheritdoc ITransferLocker
    function enqueueLifecycle(
        bytes32[] calldata playerIds,
        LifecycleReason reason,
        uint32[] calldata effectiveMins
    ) external {
        if (msg.sender != owner() && msg.sender != eligibilityVerifier) revert Errors.Unauthorized();

        uint256 length = playerIds.length;
        if (effectiveMins.length != 0 && effectiveMins.length != length) {
            revert Errors.LengthMismatch(length, effectiveMins.length);
        }

        bool isReactivate = reason == LifecycleReason.Reactivate;
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
            _pending.push(PendingLifecycle({ playerId: playerId, reason: reason, effectiveMins: mins }));
            unchecked {
                ++added;
            }
        }

        emit Events.LifecyclePlayersEnqueued(reason, added, _pending.length);
    }

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

    // -------------------------------------------------------------------------
    //  Confirm — manual / gated (NOT public yet)
    // -------------------------------------------------------------------------

    function confirmInactive( /* playerId */ ) external {
        // gated: manual review + owner setStatus(INACTIVE)
    }

    function confirmReactivate(bytes32 playerId) external view {
        // gated: manual review + owner setStatus(GRADUATED) / prior status
        _requireFeeTopologyConsistent(playerId);
    }

    // -------------------------------------------------------------------------
    //  Fee topology
    // -------------------------------------------------------------------------

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

        address domesticTreasury = tournamentRegistry.getPbrTreasury(leagueId);
        address vault = set.vaultData.playerVault;

        if (vault != address(0) && !tournamentRegistry.isVaultRegistered(leagueId, vault)) {
            revert Errors.VaultNotOnLeagueTreasury(playerId, leagueId, domesticTreasury, vault);
        }
    }
}
