// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { EligibilityGroups } from "@types/data/EligibilityTypes.sol";

/**
 * @title IDopplerLocker
 * @notice Waiting-room intake for players cleared by `EligibilityVerifier.verifyEligibility`.
 */
interface IDopplerLocker {
    /**
     * @notice Persist a page of eligible deploy cohorts for later formatting / final checks.
     * @dev Called by `EligibilityVerifier` after score sync + cohort selection.
     *      Only deploy arrays are consumed (`goalkeepers`…`newTransfers`);
     *      `toDeactivate` is handled by `ManageLifecycle`.
     */
    function enqueueEligible(EligibilityGroups calldata groups) external;
}
