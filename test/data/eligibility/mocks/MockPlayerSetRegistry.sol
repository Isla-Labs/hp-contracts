// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PlayerSet, PlayerStatus } from "@types/registries/PlayerSetTypes.sol";

/// @notice Minimal PlayerSetRegistry for eligibility classify paths.
contract MockPlayerSetRegistry {
    mapping(bytes32 playerId => bool) internal _exists;
    mapping(bytes32 playerId => PlayerSet) internal _sets;

    function seedPlayer(bytes32 playerId, PlayerStatus status, bytes32 leagueId) external {
        _exists[playerId] = true;
        _sets[playerId].status = status;
        _sets[playerId].tournamentData.leagueId = leagueId;
    }

    function clearPlayer(bytes32 playerId) external {
        delete _exists[playerId];
        delete _sets[playerId];
    }

    function setStatus(bytes32 playerId, PlayerStatus status) external {
        _sets[playerId].status = status;
    }

    function playerExists(bytes32 playerId) external view returns (bool) {
        return _exists[playerId];
    }

    function getPlayerSet(bytes32 playerId) external view returns (PlayerSet memory) {
        return _sets[playerId];
    }
}
