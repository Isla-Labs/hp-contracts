// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { EligibilityGroups } from "@src/data/eligibility/types/EligibilityTypes.sol";

/**
 * @title IDeployDoppler
 * @notice Waiting-room intake for players cleared by `EligibilityVerifier.verifyEligibility`.
 */
interface IDeployDoppler {
    /**
     * @notice Persist a page of eligible cohorts for later deploy formatting / final checks.
     * @dev Called by `EligibilityVerifier` after score sync + cohort selection.
     *      DeployDoppler parses `groups` independently (no shared mutable session).
     */
    function enqueueEligible(EligibilityGroups calldata groups) external;
}
