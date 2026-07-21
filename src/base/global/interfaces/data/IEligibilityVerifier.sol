// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IPlayerSetRegistry } from "@base/global/interfaces/IPlayerSetRegistry.sol";
import {
    Appearance,
    EligibilityBucket,
    EligibilityGroups,
    MinutesStore
} from "@src/data/eligibility/types/EligibilityTypes.sol";

/**
 * @title IEligibilityVerifier
 * @notice Accumulates per-position minutes for all appearing players, backfills DOBs via CRE,
 *         and exposes onchain eligibility checks against previous-season minute thresholds.
 */
interface IEligibilityVerifier {
    function recordAppearances(Appearance[] calldata appearances) external;

    /// @notice Walks tracked players and enqueues any with unset `birthDate`; emits fetch-needed.
    function scanMissingBirthDates(uint256 offset, uint256 limit) external returns (bytes32[] memory queued);

    /**
     * @notice Page over tracked players and return undeployed candidates that clear their cohort threshold.
     * @dev Skips unset `birthDate` and any `playerId` already present in `PlayerSetRegistry`.
     *      Cohorts (same priority as the original TS edge fn):
     *      - GK (`expectedPosition == GK`): ≥ 361 mins
     *      - under 21: ≥ 181 mins
     *      - else: ≥ 901 mins
     */
    function verifyEligibility(uint256 offset, uint256 limit) external view returns (EligibilityGroups memory groups);

    /// @notice Single-player check (does not filter on deployment status).
    function isEligible(bytes32 playerId)
        external
        view
        returns (bool eligible, EligibilityBucket bucket, uint32 totalMins);

    function playerSetRegistry() external view returns (IPlayerSetRegistry);

    function playerCount() external view returns (uint256);

    function playerIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory);

    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory);

    function totalMinsPlayed(bytes32 playerId) external view returns (uint32);

    function pendingBirthDateCount() external view returns (uint256);

    function pendingBirthDateIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory);
}
