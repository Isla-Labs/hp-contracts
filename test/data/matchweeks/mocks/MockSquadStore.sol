// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { SquadFetchPhase } from "@types/data/SquadStoreTypes.sol";

/// @notice SquadStore peer stub for RoundManager Live transition + OpenSeason adopt.
contract MockSquadStore {
    mapping(bytes32 leagueId => SquadFetchPhase) internal _phase;

    bytes32 public lastAdoptLeagueId;
    bytes32 public lastAdoptSeasonId;
    uint16 public lastAdoptYear;
    uint256 public adoptSeasonCount;

    function setFetchPhase(bytes32 leagueId, SquadFetchPhase phase) external {
        _phase[leagueId] = phase;
    }

    function getFetchPhase(bytes32 leagueId) external view returns (SquadFetchPhase) {
        return _phase[leagueId];
    }

    function adoptSeason(bytes32 leagueId, bytes32 seasonId, uint16 seasonStartYear) external {
        lastAdoptLeagueId = leagueId;
        lastAdoptSeasonId = seasonId;
        lastAdoptYear = seasonStartYear;
        unchecked {
            ++adoptSeasonCount;
        }
    }
}
