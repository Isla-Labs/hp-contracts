// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IDeployDoppler } from "@base/global/interfaces/data/IDeployDoppler.sol";
import { IPlayerSetRegistry } from "@base/global/interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@base/global/interfaces/ITournamentRegistry.sol";
import {
    Appearance,
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

    /// @notice Stored score from the last `verifyEligibility` page that touched this player.
    function weightedScore(bytes32 playerId) external view returns (uint256 scoreWad, uint32 effectiveMins);

    function playerSetRegistry() external view returns (IPlayerSetRegistry);

    function tournamentRegistry() external view returns (ITournamentRegistry);

    function deployDoppler() external view returns (IDeployDoppler);

    function ppmVerifier() external view returns (address);

    function leagueId() external view returns (bytes32);

    function baseYear() external view returns (uint16);

    function playerCount() external view returns (uint256);

    function playerIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory);

    function playerExists(bytes32 playerId) external view returns (bool);

    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory);

    function totalMinsPlayed(bytes32 playerId) external view returns (uint32);

    /// @notice CRE cursor: SP `_pgNm` to request next (`0` → `1`; done → `(0, true)`).
    function nextSquadFillPageToFetch(bytes32 seasonId) external view returns (uint16 pageToFetch, bool done);

    /// @notice Timestamp when `seasonId` last hit `SQUAD_FILL_PAGE_DONE` (0 if never).
    function getLastSquadFillSweepAt(bytes32 seasonId) external view returns (uint256);
}
