// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { EligibilityGroups } from "@src/data/eligibility/types/EligibilityTypes.sol";

/**
 * @title IDeployDoppler
 * @notice Waiting-room intake for players cleared by `EligibilityVerifier.verifyEligibility`.
 */
interface IDeployDoppler {
    /**
     * @notice Persist a page of eligible deploy cohorts for later formatting / final checks.
     * @dev Called by `EligibilityVerifier` after score sync + cohort selection.
     *      Only deploy arrays are consumed (`goalkeepers`…`newTransfers`); `toDiscontinue` is ignored.
     */
    function enqueueEligible(EligibilityGroups calldata groups) external;
}
