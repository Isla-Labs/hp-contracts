// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IDopplerLocker
 * @notice Waiting-room intake for players cleared by the eligibility data plane.
 */
interface IDopplerLocker {
    /**
     * @notice Queue eligible players for metadata fetch + 24h review + deploy.
     * @dev Called by `EligibilityVerifier` or Orchestrator owner.
     *      Parallel arrays: `playerIds[i]` belongs to `leagueIds[i]` (calendar HPID).
     */
    function enqueueEligible(bytes32[] calldata playerIds, bytes32[] calldata leagueIds) external;
}
