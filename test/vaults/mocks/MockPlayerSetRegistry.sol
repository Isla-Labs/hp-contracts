// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { TournamentData } from "@types/registries/PlayerSetTypes.sol";

/// @notice Records utilization flips from PlayerVault stake/unstake.
contract MockPlayerSetRegistry {
    bool public lastUtilized;
    uint256 public updateCount;
    address public lastCaller;

    mapping(bytes32 playerId => bytes32[]) internal _activeTournaments;

    function setActiveTournaments(bytes32 playerId, bytes32[] calldata tournamentIds) external {
        delete _activeTournaments[playerId];
        for (uint256 i; i < tournamentIds.length; ++i) {
            _activeTournaments[playerId].push(tournamentIds[i]);
        }
    }

    function updateUtilization(bool isUtilized) external {
        lastUtilized = isUtilized;
        lastCaller = msg.sender;
        unchecked {
            ++updateCount;
        }
    }

    function getTournamentData(bytes32 playerId) external view returns (TournamentData memory data) {
        data.leagueId = bytes32(0);
        data.activeTournaments = _activeTournaments[playerId];
    }
}
