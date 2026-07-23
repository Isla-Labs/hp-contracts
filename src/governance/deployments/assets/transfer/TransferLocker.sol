// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { LifecycleErrors as Errors } from "@base/global/libraries/errors/LifecycleErrors.sol";
import { LifecycleEvents as Events } from "@base/global/libraries/events/LifecycleEvents.sol";
import { ITransferLocker } from "@base/global/interfaces/governance/ITransferLocker.sol";
import { LifecycleReason, PendingLifecycle } from "@base/global/types/LifecycleTypes.sol";

/**
 * @title TransferLocker
 * @notice Waiting room for soft-inactivity / reactivation candidates (mirrors DopplerLocker).
 * @dev Flow:
 *      0) EligibilityVerifier enqueues continuity failures, league-leavers, or reactivations.
 *      1) Offchain / manual review (webhook + email — TBD) confirms or rejects.
 *      2) Confirmed deactivate → Automator → `setStatus(INACTIVE)` (not wired yet).
 *      3) Confirmed reactivate → Automator → restore prior active status (not wired yet).
 *
 *      Deactivate and reactivate queues are independent so a prior deactivate enqueue
 *      does not block a later reactivate enqueue (and vice versa).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TransferLocker is ITransferLocker {
    /// @notice Sole writer for `enqueueLifecycle` (set once after EligibilityVerifier deploy).
    address public eligibilityVerifier;

    PendingLifecycle[] private _pending;
    /// @dev ContinuityUnderThreshold / LeftLeague — pending soft-inactive review.
    mapping(bytes32 playerId => bool) private _queuedDeactivate;
    /// @dev Reactivate — pending restore-from-INACTIVE review.
    mapping(bytes32 playerId => bool) private _queuedReactivate;

    /// @notice One-time wire from EligibilityVerifier → this waiting room.
    function setEligibilityVerifier(address eligibilityVerifier_) external {
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
        if (msg.sender != eligibilityVerifier) revert Errors.Unauthorized();

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
            _pending.push(
                PendingLifecycle({ playerId: playerId, reason: reason, effectiveMins: mins })
            );
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
    function pendingLifecycle(uint256 offset, uint256 limit)
        external
        view
        returns (PendingLifecycle[] memory out)
    {
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
    function confirmInactive(/* playerId */) external {
        // gated: manual review + Automator setStatus(INACTIVE)
    }

    /**
     * After waiting-room review confirms PBR reactivation:
     * - Require status == INACTIVE and continuity still holds.
     * - Automator → restore prior active status (typically GRADUATED).
     * - Clear `_queuedReactivate` for the player.
     *
     * Access: gated (timelock / proposer).
     */
    function confirmReactivate(/* playerId */) external {
        // gated: manual review + Automator setStatus(GRADUATED) / prior status
    }
}
