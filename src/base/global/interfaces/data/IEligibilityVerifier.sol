// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IDeployDoppler } from "@base/global/interfaces/data/IDeployDoppler.sol";
import { IPlayerSetRegistry } from "@base/global/interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@base/global/interfaces/ITournamentRegistry.sol";
import {
    Appearance,
    EligibilityBucket,
    EligibilityGroups,
    MinutesStore
} from "@src/data/eligibility/types/EligibilityTypes.sol";

/**
 * @title IEligibilityVerifier
 * @notice Squad-first eligibility store with a recency-weighted rolling minutes score.
 */
interface IEligibilityVerifier {
    function recordAppearances(bytes32 seasonId, uint16 seasonStartYear, Appearance[] calldata appearances)
        external;

    /**
     * @notice Recompute weighted scores for a page, enqueue to DeployDoppler, return cohorts.
     * @dev Offchain runner entrypoint — sole write path for `weightedScoreWad`.
     *      Skips unset `birthDate` and any `playerId` already present in `PlayerSetRegistry`.
     *      `groups.newTransfers` is the DeployDoppler flag for newTransfer / backFromLoan.
     */
    function verifyEligibility(uint256 offset, uint256 limit) external returns (EligibilityGroups memory groups);

    /// @notice Single-player check (does not filter on deployment status).
    /// @dev View-only replay of appearances (does not write storage). Prefer `verifyEligibility` for the runner.
    /// @return eligible Whether the recomputed weighted score clears the cohort threshold.
    /// @return bucket Cohort used for the threshold (newTransfer / GK / u21 / outfield).
    /// @return effectiveMins Truncated recomputed weighted score (`scoreWad / 1e18`).
    function isEligible(bytes32 playerId)
        external
        view
        returns (bool eligible, EligibilityBucket bucket, uint32 effectiveMins);

    /// @notice Stored score from the last `verifyEligibility` page that touched this player.
    function weightedScore(bytes32 playerId) external view returns (uint256 scoreWad, uint32 effectiveMins);

    /// @notice True when `weightedScoreWad == 0 && earliestSeasonStartYear == currentSeasonYear`.
    /// @dev Pending newTransfer / backFromLoan flag (no league-weighted minutes yet this season).
    function isPendingSeasonEntrant(bytes32 playerId) external view returns (bool);

    function playerSetRegistry() external view returns (IPlayerSetRegistry);

    function tournamentRegistry() external view returns (ITournamentRegistry);

    function deployDoppler() external view returns (IDeployDoppler);

    function leagueId() external view returns (bytes32);

    function baseYear() external view returns (uint16);

    function roundsPerSeason() external view returns (uint32);

    function playerCount() external view returns (uint256);

    function playerIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory);

    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory);

    function totalMinsPlayed(bytes32 playerId) external view returns (uint32);
}
