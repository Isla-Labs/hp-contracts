// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundFetchPhase, SeasonRef, TournamentRoundFetch } from "@types/data/RoundManagerTypes.sol";

/// @notice RoundManager stub exposing seasons for PbrHistorical.openHistorical.
contract MockRoundManager {
    mapping(bytes32 tournamentId => SeasonRef[]) internal _seasons;
    mapping(bytes32 tournamentId => RoundFetchPhase) internal _phase;

    function setSeasons(bytes32 tournamentId, SeasonRef[] memory seasons) external {
        delete _seasons[tournamentId];
        for (uint256 i; i < seasons.length; ++i) {
            _seasons[tournamentId].push(seasons[i]);
        }
        _phase[tournamentId] = RoundFetchPhase.Live;
    }

    function getFetchState(bytes32 tournamentId) external view returns (TournamentRoundFetch memory state) {
        SeasonRef[] storage seasons = _seasons[tournamentId];
        state.phase = _phase[tournamentId];
        state.seasons = new SeasonRef[](seasons.length);
        for (uint256 i; i < seasons.length; ++i) {
            state.seasons[i] = seasons[i];
        }
    }

    function getFetchPhase(bytes32 tournamentId) external view returns (RoundFetchPhase) {
        return _phase[tournamentId];
    }
}
