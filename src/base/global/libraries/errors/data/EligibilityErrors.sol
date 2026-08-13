// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library EligibilityErrors {
    error ZeroAddress();
    error ZeroId();
    error Unauthorized();
    error ArrayLengthsMismatch();
    error FetchAlreadyActive(bytes32 leagueId);
    error DuplicateSeasonYear(uint16 seasonStartYear);
    error UnexpectedFetchStep(uint8 actual);
    error NotLive(bytes32 leagueId);
    error ZeroBirthDate(bytes32 playerId);
    error LengthMismatch(uint256 playerIdsLength, uint256 birthDatesLength);
    error InvalidThreshold();

    error TransientSeasonMismatch(bytes32 expected, bytes32 received);
    error TransientIncomplete(bytes32 seasonId, uint16 nextPage);
    error FetchPageMismatch(bytes32 seasonId, uint16 expected, uint16 received);
    error FetchOffsetMismatch(bytes32 seasonId, uint16 expected, uint16 received);
    error InvalidNextPage(uint16 pageFetched, uint16 nextPage);

    error OracleRequestPending(bytes32 requestId);
    error UnknownOracleRequest(bytes32 requestId);
}
