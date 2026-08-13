// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Captures Live OpenSeason `openSeason` from RoundManager.
contract MockTournamentInitializer {
    bytes32 public lastTournamentId;
    bytes32 public lastSeasonId;
    uint16 public lastSeasonStartYear;
    uint32 public lastFinalRound;
    uint256 public openSeasonCount;

    function openSeason(bytes32 tournamentId, bytes32 seasonId, uint16 seasonStartYear, uint32 finalRound) external {
        lastTournamentId = tournamentId;
        lastSeasonId = seasonId;
        lastSeasonStartYear = seasonStartYear;
        lastFinalRound = finalRound;
        unchecked {
            ++openSeasonCount;
        }
    }
}
