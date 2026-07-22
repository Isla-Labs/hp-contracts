// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library EligibilityErrors {
    error ZeroAddress();
    error ZeroId();
    error ZeroWorkflowId();
    error Unauthorized();
    error ZeroBirthDate(bytes32 playerId);
    error UnknownPlayer(bytes32 playerId);
    error LengthMismatch(uint256 playerIdsLength, uint256 birthDatesLength);
    error SquadFillSeasonDone(bytes32 seasonId);
    error SquadFillPageMismatch(bytes32 seasonId, uint16 expected, uint16 received);
    error InvalidSquadFillNextPage(uint16 pageFetched, uint16 nextPage);
}
