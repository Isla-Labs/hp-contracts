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
    error InvalidThreshold();

    // --------------------------------------------
    //  Squads workflow (eligibility-3)
    // --------------------------------------------

    error NoActivePass();
    error PassActive();
    error NoCurrentSeasonYear();
    error NoQueuedWork();
    error LeagueAlreadyQueued(bytes32 leagueId);
    error SeasonsNotAscending();
    error NotActiveSeason(bytes32 leagueId, bytes32 seasonId);
    error SeasonNotFetchable(bytes32 seasonId);
    error SeasonNotSortable(bytes32 seasonId);
    error TransientSeasonMismatch(bytes32 expected, bytes32 received);
    error TransientIncomplete(bytes32 seasonId, uint16 nextPage);
    error FetchPageMismatch(bytes32 seasonId, uint16 expected, uint16 received);
    error FetchOffsetMismatch(bytes32 seasonId, uint16 expected, uint16 received);
    error InvalidNextPage(uint16 pageFetched, uint16 nextPage);
    error UnknownSquadPhase();
}
