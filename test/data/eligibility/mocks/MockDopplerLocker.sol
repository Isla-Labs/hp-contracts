// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Captures `queueAssets` calls from EligibilityVerifier (MarketInitializer stand-in).
contract MockDopplerLocker {
    struct QueueCall {
        bytes32 leagueId;
        bytes32 seasonId;
        bytes32[] playerIds;
    }

    QueueCall[] internal _calls;

    function queueAssets(bytes32 leagueId, bytes32 seasonId, bytes32[] calldata playerIds) external {
        _calls.push();
        QueueCall storage c = _calls[_calls.length - 1];
        c.leagueId = leagueId;
        c.seasonId = seasonId;
        for (uint256 i; i < playerIds.length; ++i) {
            c.playerIds.push(playerIds[i]);
        }
    }

    function callCount() external view returns (uint256) {
        return _calls.length;
    }

    function callAt(uint256 index)
        external
        view
        returns (bytes32 leagueId, bytes32 seasonId, bytes32[] memory playerIds)
    {
        QueueCall storage c = _calls[index];
        return (c.leagueId, c.seasonId, c.playerIds);
    }

    function totalQueuedPlayers() external view returns (uint256 n) {
        for (uint256 i; i < _calls.length; ++i) {
            n += _calls[i].playerIds.length;
        }
    }

    function wasQueued(bytes32 playerId) external view returns (bool) {
        for (uint256 i; i < _calls.length; ++i) {
            bytes32[] storage ids = _calls[i].playerIds;
            for (uint256 j; j < ids.length; ++j) {
                if (ids[j] == playerId) return true;
            }
        }
        return false;
    }
}
