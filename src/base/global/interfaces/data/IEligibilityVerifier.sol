// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Appearance, MinutesStore } from "@src/data/eligibility/types/EligibilityTypes.sol";

/**
 * @title IEligibilityVerifier
 * @notice Accumulates per-position minutes for all appearing players and backfills DOBs via CRE.
 */
interface IEligibilityVerifier {
    function recordAppearances(Appearance[] calldata appearances) external;

    /// @notice Walks tracked players and enqueues any with unset `birthDate`; emits fetch-needed.
    function scanMissingBirthDates(uint256 offset, uint256 limit) external returns (bytes32[] memory queued);

    function playerCount() external view returns (uint256);

    function playerIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory);

    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory);

    function pendingBirthDateCount() external view returns (uint256);

    function pendingBirthDateIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory);
}
