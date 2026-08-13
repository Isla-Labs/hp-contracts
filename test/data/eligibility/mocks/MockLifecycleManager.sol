// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { LifecycleReason } from "@types/initializers/LifecycleTypes.sol";

/// @notice Captures `enqueueLifecycle` calls from Orchestrator (LifecycleManager stand-in).
contract MockLifecycleManager {
    struct EnqueueCall {
        bytes32[] playerIds;
        LifecycleReason reason;
        uint32[] effectiveMins;
    }

    EnqueueCall[] internal _calls;

    function enqueueLifecycle(
        bytes32[] calldata playerIds,
        LifecycleReason reason,
        uint32[] calldata effectiveMins
    ) external {
        _calls.push();
        EnqueueCall storage c = _calls[_calls.length - 1];
        c.reason = reason;
        for (uint256 i; i < playerIds.length; ++i) {
            c.playerIds.push(playerIds[i]);
        }
        for (uint256 i; i < effectiveMins.length; ++i) {
            c.effectiveMins.push(effectiveMins[i]);
        }
    }

    function callCount() external view returns (uint256) {
        return _calls.length;
    }

    function callAt(uint256 index)
        external
        view
        returns (bytes32[] memory playerIds, LifecycleReason reason, uint32[] memory effectiveMins)
    {
        EnqueueCall storage c = _calls[index];
        return (c.playerIds, c.reason, c.effectiveMins);
    }

    function wasEnqueued(bytes32 playerId, LifecycleReason reason) external view returns (bool) {
        for (uint256 i; i < _calls.length; ++i) {
            if (_calls[i].reason != reason) continue;
            bytes32[] storage ids = _calls[i].playerIds;
            for (uint256 j; j < ids.length; ++j) {
                if (ids[j] == playerId) return true;
            }
        }
        return false;
    }

    function effectiveMinsFor(bytes32 playerId, LifecycleReason reason) external view returns (uint32) {
        for (uint256 i; i < _calls.length; ++i) {
            if (_calls[i].reason != reason) continue;
            bytes32[] storage ids = _calls[i].playerIds;
            for (uint256 j; j < ids.length; ++j) {
                if (ids[j] == playerId) {
                    if (_calls[i].effectiveMins.length == 0) return 0;
                    return _calls[i].effectiveMins[j];
                }
            }
        }
        return 0;
    }
}
