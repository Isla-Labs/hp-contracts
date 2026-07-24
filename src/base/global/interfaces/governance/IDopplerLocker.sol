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
     * @dev Called by `Automator` only (EV relays via `executeAutomation`).
     *      Only deploy arrays are consumed (`goalkeepers`…`newTransfers`);
     *      `toDeactivate` is handled by `TransferLocker`.
     */
    function enqueueEligible(EligibilityGroups calldata groups) external;
}
