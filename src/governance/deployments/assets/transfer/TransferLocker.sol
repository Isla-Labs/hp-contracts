// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { LifecycleErrors as Errors } from "@errors/governance/LifecycleErrors.sol";
import { LifecycleEvents as Events } from "@events/governance/LifecycleEvents.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { ITransferLocker } from "@interfaces/governance/ITransferLocker.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";
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
 *      0) EligibilityVerifier (via Automator) enqueues continuity failures, league-leavers, or reactivations.
 *      1) Offchain / manual review (webhook + email — TBD) confirms or rejects.
 *      2) Confirmed deactivate → Automator → `setStatus(INACTIVE)` (not wired yet).
 *      3) Confirmed reactivate → Automator → restore prior active status (not wired yet).
 *
 *      Cross-league moves (e.g. Bundesliga → EPL) are not standard continuity reactivates:
 *      deactivate in the old league first, migrate `PlayerSet.leagueId` + `FeeRouter.pbrFeeHub`
 *      (+ vault ↔ `PbrTreasury` registration), then reactivate. `confirmReactivate` refuses
 *      unless `leagueId → PbrFeeHub / PbrTreasury` topology still matches.
 *
 *      Deactivate and reactivate queues are independent so a prior deactivate enqueue
 *      does not block a later reactivate enqueue (and vice versa).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TransferLocker is ITransferLocker {
    /// @notice Canonical player market index.
    IPlayerSetRegistry public immutable playerSetRegistry;

    /// @notice Domestic hub + tournament treasury topology.
    ITournamentRegistry public immutable tournamentRegistry;

    /// @notice Sole writer for `enqueueLifecycle` (Automator; set once after Automator deploy).
    address public automator;

    PendingLifecycle[] private _pending;
    /// @dev ContinuityUnderThreshold / LeftLeague — pending soft-inactive review.
    mapping(bytes32 playerId => bool) private _queuedDeactivate;
    /// @dev Reactivate — pending restore-from-INACTIVE review.
    mapping(bytes32 playerId => bool) private _queuedReactivate;

    /**
     * @param playerSetRegistry_ Canonical `PlayerSetRegistry` proxy.
     * @param tournamentRegistry_ Canonical `TournamentRegistry` proxy.
     */
    constructor(address playerSetRegistry_, address tournamentRegistry_) {
        if (playerSetRegistry_ == address(0) || tournamentRegistry_ == address(0)) revert Errors.ZeroAddress();
        playerSetRegistry = IPlayerSetRegistry(playerSetRegistry_);
        tournamentRegistry = ITournamentRegistry(tournamentRegistry_);
    }

    /// @notice One-time wire: Automator is the only `enqueueLifecycle` caller.
    function setAutomator(address automator_) external {
        if (automator != address(0)) revert Errors.AlreadySet();
        if (automator_ == address(0)) revert Errors.ZeroAddress();
        automator = automator_;
        emit Events.AutomatorSet(automator_);
    }

    /// @inheritdoc ITransferLocker
    function enqueueLifecycle(
        bytes32[] calldata playerIds,
        LifecycleReason reason,
        uint32[] calldata effectiveMins
    ) external {
        if (msg.sender != automator) revert Errors.Unauthorized();

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

    /**
     * After waiting-room review confirms soft-inactivity:
     * - Require still deployed and not already INACTIVE.
     * - Automator → PlayerSetRegistry.setStatus(INACTIVE).
     * - Clear `_queuedDeactivate` for the player.
     *
     * Access: gated (timelock / proposer) — mirror DopplerLocker deploy path.
     */
    function confirmInactive( /* playerId */ ) external {
        // gated: manual review + Automator setStatus(INACTIVE)
    }

    /**
     * After waiting-room review confirms PBR reactivation:
     * - Require status == INACTIVE and continuity still holds.
     * - Require `leagueId → FeeRouter.pbrFeeHub / PbrTreasury` topology matches (cross-league
     *   hub + vault migration must complete before this call).
     * - Automator → restore prior active status (typically GRADUATED).
     * - Clear `_queuedReactivate` for the player.
     *
     * Access: gated (timelock / proposer).
     */
    function confirmReactivate(bytes32 playerId) external {
        // gated: manual review + Automator setStatus(GRADUATED) / prior status
        // Topology gate is live now so cross-league reactivates cannot skip hub migration.
        _requireFeeTopologyConsistent(playerId);
    }

    // -------------------------------------------------------------------------
    //  Fee topology
    // -------------------------------------------------------------------------

    /**
     * @dev Ensures the player's recorded domestic league still lines up with fee routing
     *      and treasury registration before status is restored.
     *
     *      Checks:
     *      1) `tournamentData.leagueId` set and hub registered.
     *      2) `FeeRouter.pbrFeeHub == TournamentRegistry.pbrFeeHubOf(leagueId)`.
     *      3) Domestic-league treasury exists (`tournamentId == leagueId`).
     *      4) Every `activeTournament` is linked to that league and has a treasury.
     *      5) If a player vault exists: registered on the domestic treasury and on each
     *         active tournament treasury.
     */
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

        // Domestic league tournament id equals `leagueId` (see TournamentRegistry.createTournament).
        address domesticTreasury = tournamentRegistry.getPbrTreasury(leagueId);

        bytes32[] memory linked = tournamentRegistry.getTournamentsForLeague(leagueId);
        bytes32[] memory active = set.tournamentData.activeTournaments;
        uint256 activeLen = active.length;

        for (uint256 i; i < activeLen; ++i) {
            bytes32 tournamentId = active[i];
            if (!_containsId(linked, tournamentId)) {
                revert Errors.ActiveTournamentNotLinked(playerId, leagueId, tournamentId);
            }

            // Reverts `NotFound` if the tournament / treasury was never created.
            address treasury = tournamentRegistry.getPbrTreasury(tournamentId);

            address vault = set.vaultData.playerVault;
            if (vault != address(0) && !IPbrTreasury(treasury).isVault(vault)) {
                revert Errors.VaultNotOnTournamentTreasury(playerId, tournamentId, treasury, vault);
            }
        }

        address vault = set.vaultData.playerVault;
        if (vault != address(0) && !IPbrTreasury(domesticTreasury).isVault(vault)) {
            revert Errors.VaultNotOnLeagueTreasury(playerId, leagueId, domesticTreasury, vault);
        }
    }

    function _containsId(bytes32[] memory ids, bytes32 id) private pure returns (bool) {
        uint256 length = ids.length;
        for (uint256 i; i < length; ++i) {
            if (ids[i] == id) return true;
        }
        return false;
    }
}
