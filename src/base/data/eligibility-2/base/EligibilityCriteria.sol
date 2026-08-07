// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";

import { EligibilityErrors as Errors } from "@errors/data/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@events/data/EligibilityEvents.sol";

/**
 * @title EligibilityCriteria
 * @notice Owner-updatable deploy / continuity thresholds for `EligibilityVerifier`.
 * @dev Ringfenced policy module (same idea as `DopplerConfig`). Defaults match the original
 *      hardcoded constants. Call `__EligibilityCriteria_init` from the concrete verifier's
 *      `initialize` (guarded by `initializer` there). Owner is transferred to Orchestrator
 *      in the concrete contract.
 *
 *      Effective-minute comparisons use `weightedScoreWad / SCORE_WAD`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
abstract contract EligibilityCriteria is Ownable {
    // -------------------------------------------------------------------------
    //  Storage — shared until owner updates
    // -------------------------------------------------------------------------

    /// @notice GK continuity / deploy threshold (effective minutes).
    uint32 public thresholdGk;

    /// @notice Under-21 continuity / deploy threshold (effective minutes).
    uint32 public thresholdUnder21;

    /// @notice Outfield continuity / deploy threshold (effective minutes).
    uint32 public thresholdOutfield;

    /// @notice newTransfer / backFromLoan deploy threshold (effective minutes).
    uint32 public thresholdNewTransfer;

    /// @notice Age cutoff for under-21 cohort (whole years).
    uint256 public under21Age;

    // -------------------------------------------------------------------------
    //  Initialization
    // -------------------------------------------------------------------------

    function __EligibilityCriteria_init() internal {
        _applyThresholds(361, 181, 901, 1, 21);
    }

    // -------------------------------------------------------------------------
    //  Views
    // -------------------------------------------------------------------------

    /// @notice Snapshot of all owner-tunable criteria.
    function eligibilityCriteria()
        external
        view
        returns (
            uint32 thresholdGk_,
            uint32 thresholdUnder21_,
            uint32 thresholdOutfield_,
            uint32 thresholdNewTransfer_,
            uint256 under21Age_
        )
    {
        return (thresholdGk, thresholdUnder21, thresholdOutfield, thresholdNewTransfer, under21Age);
    }

    // -------------------------------------------------------------------------
    //  Owner setters
    // -------------------------------------------------------------------------

    /**
     * @notice Replace all eligibility thresholds (deploy + continuity).
     * @dev Does not rewrite stored scores; next `verifyEligibility` page uses the new gates.
     */
    function setEligibilityThresholds(
        uint32 thresholdGk_,
        uint32 thresholdUnder21_,
        uint32 thresholdOutfield_,
        uint32 thresholdNewTransfer_,
        uint256 under21Age_
    ) external onlyOwner {
        _applyThresholds(thresholdGk_, thresholdUnder21_, thresholdOutfield_, thresholdNewTransfer_, under21Age_);
        emit Events.EligibilityThresholdsUpdated(
            thresholdGk_, thresholdUnder21_, thresholdOutfield_, thresholdNewTransfer_, under21Age_
        );
    }

    // -------------------------------------------------------------------------
    //  Internal
    // -------------------------------------------------------------------------

    function _applyThresholds(
        uint32 thresholdGk_,
        uint32 thresholdUnder21_,
        uint32 thresholdOutfield_,
        uint32 thresholdNewTransfer_,
        uint256 under21Age_
    ) internal {
        if (
            thresholdGk_ == 0 || thresholdUnder21_ == 0 || thresholdOutfield_ == 0 || thresholdNewTransfer_ == 0
                || under21Age_ == 0
        ) {
            revert Errors.InvalidThreshold();
        }

        thresholdGk = thresholdGk_;
        thresholdUnder21 = thresholdUnder21_;
        thresholdOutfield = thresholdOutfield_;
        thresholdNewTransfer = thresholdNewTransfer_;
        under21Age = under21Age_;
    }
}
