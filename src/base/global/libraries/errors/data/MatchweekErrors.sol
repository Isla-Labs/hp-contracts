// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library MatchweekErrors {
    error ZeroAddress();
    error ZeroId();
    error Unauthorized();
    error ArrayLengthsMismatch();
    error FetchAlreadyActive(bytes32 tournamentId);
    error UnknownOracleRequest(bytes32 requestId);
    error OracleRequestPending(bytes32 requestId);
    error RoundNotFound(bytes32 tournamentId, uint16 seasonStartYear, uint32 roundNumber);
    error InvalidFinalRound();
    error InvalidRoundNumber(uint32 roundNumber, uint32 finalRound);
    error InvalidTimeRange(uint64 startTime, uint64 endTime);
    error DuplicateSeasonYear(uint16 seasonStartYear);
    error EmptyRounds();
    error UnexpectedFetchStep(uint8 actual);
    error RoundCountMismatch(uint32 expected, uint32 actual);
    error NotLive(bytes32 tournamentId);
    error UnexpectedLiveKind(uint8 kind);
}
