// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AccessRoles as Roles } from "@base/global/libraries/roles/AccessRoles.sol";
import { EligibilityErrors as Errors } from "@base/global/libraries/errors/data/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@base/global/libraries/events/data/EligibilityEvents.sol";

/**
 * @title EligibilityCriteria
 * @notice Governance-updatable deploy / continuity thresholds for `EligibilityVerifier`.
 * @dev Mirrors the `DopplerConfig` pattern: ringfenced criteria, `CATEGORY_ONE` may update
 *      without redeploying the verifier. Defaults match the original hardcoded constants.
 *
 *      Effective-minute comparisons use `weightedScoreWad / SCORE_WAD`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
abstract contract EligibilityCriteria is Initializable, AccessControl {
    // -------------------------------------------------------------------------
    //  Storage — shared until governance updates
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

    /**
     * @param constitutionalTimelock_ `ConstitutionalTimelock` — `CATEGORY_ONE` config updates.
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE`.
     */
    function __EligibilityCriteria_init(address constitutionalTimelock_, address dao_) internal onlyInitializing {
        if (constitutionalTimelock_ == address(0) || dao_ == address(0)) revert Errors.ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_ONE, constitutionalTimelock_);

        _applyThresholds(361, 181, 901, 1, 21);
    }

    // -------------------------------------------------------------------------
    //  Views
    // -------------------------------------------------------------------------

    /// @notice Snapshot of all governance-tunable criteria.
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
    //  Governance setters — CATEGORY_ONE
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
    ) external onlyRole(Roles.CATEGORY_ONE) {
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
