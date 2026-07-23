// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { LifecycleErrors as Errors } from "@base/global/libraries/errors/LifecycleErrors.sol";
import { LifecycleEvents as Events } from "@base/global/libraries/events/LifecycleEvents.sol";
import { IManageLifecycle } from "@base/global/interfaces/data/IManageLifecycle.sol";
import { LifecycleReason, PendingLifecycle } from "@base/global/types/LifecycleTypes.sol";

/**
 * @title ManageLifecycle
 * @notice Waiting room for soft-inactivity candidates (mirrors DeployDoppler intake).
 * @dev Flow:
 *      0) EligibilityVerifier enqueues continuity failures / league-leavers.
 *      1) Offchain / manual review (webhook + email — TBD) confirms or rejects.
 *      2) Confirmed → Automator → `PlayerSetRegistry.setStatus(INACTIVE)` (not wired yet).
 *
 *      Only the configured `eligibilityVerifier` may call `enqueueLifecycle`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract ManageLifecycle is IManageLifecycle {
    /// @notice Sole writer for `enqueueLifecycle` (set once after EligibilityVerifier deploy).
    address public eligibilityVerifier;

    PendingLifecycle[] private _pending;
    mapping(bytes32 playerId => bool) private _queued;

    /// @notice One-time wire from EligibilityVerifier → this waiting room.
    function setEligibilityVerifier(address eligibilityVerifier_) external {
        if (eligibilityVerifier != address(0)) revert Errors.AlreadySet();
        if (eligibilityVerifier_ == address(0)) revert Errors.ZeroAddress();
        eligibilityVerifier = eligibilityVerifier_;
        emit Events.EligibilityVerifierSet(eligibilityVerifier_);
    }

    /// @inheritdoc IManageLifecycle
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

        uint256 added;
        for (uint256 i; i < length; ++i) {
            bytes32 playerId = playerIds[i];
            if (playerId == bytes32(0) || _queued[playerId]) continue;

            uint32 mins = effectiveMins.length == 0 ? 0 : effectiveMins[i];

            _queued[playerId] = true;
            _pending.push(
                PendingLifecycle({ playerId: playerId, reason: reason, effectiveMins: mins })
            );
            unchecked {
                ++added;
            }
        }

        emit Events.LifecyclePlayersEnqueued(reason, added, _pending.length);
    }

    /// @inheritdoc IManageLifecycle
    function pendingCount() external view returns (uint256) {
        return _pending.length;
    }

    /// @inheritdoc IManageLifecycle
    function isQueued(bytes32 playerId) external view returns (bool) {
        return _queued[playerId];
    }

    /// @inheritdoc IManageLifecycle
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
    //  Confirm inactivity — manual / gated (NOT public yet)
    // -------------------------------------------------------------------------

    /**
     * After waiting-room review confirms soft-inactivity:
     * - Require still deployed and not already INACTIVE.
     * - Automator → PlayerSetRegistry.setStatus(INACTIVE).
     * - Mark pending entry consumed (TBD storage shape).
     *
     * Access: gated (timelock / proposer) — mirror DeployDoppler deploy path.
     */
    function confirmInactive(/* playerId */) external {
        // gated: manual review + Automator setStatus(INACTIVE)
    }
}
