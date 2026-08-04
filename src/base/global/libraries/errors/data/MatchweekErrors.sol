// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library MatchweekErrors {
    error ZeroId();
    error SeasonNotOpen(bytes32 tournamentId, uint16 seasonStartYear);
    error RoundNotFound(bytes32 tournamentId, uint16 seasonStartYear, uint32 roundNumber);
    error InvalidFinalRound();
    error InvalidRoundNumber(uint32 roundNumber, uint32 finalRound);
    error InvalidTimeRange(uint64 startTime, uint64 endTime);
}
