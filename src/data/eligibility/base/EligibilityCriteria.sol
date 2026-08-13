// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { EligibilityErrors as Errors } from "@errors/data/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@events/data/EligibilityEvents.sol";

/**
 * @title EligibilityCriteria
 * @notice Deploy / continuity threshold storage for `EligibilityVerifier`.
 * @dev Concrete verifier gates `setEligibilityThresholds` (e.g. `TIMELOCK`).
 */
abstract contract EligibilityCriteria {
    uint32 public thresholdGk;
    uint32 public thresholdUnder21;
    uint32 public thresholdOutfield;
    uint32 public thresholdNewTransfer;
    uint256 public under21Age;

    function __EligibilityCriteria_init() internal {
        _applyThresholds(361, 181, 901, 1, 21);
    }

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

    function _setEligibilityThresholds(
        uint32 thresholdGk_,
        uint32 thresholdUnder21_,
        uint32 thresholdOutfield_,
        uint32 thresholdNewTransfer_,
        uint256 under21Age_
    ) internal {
        _applyThresholds(thresholdGk_, thresholdUnder21_, thresholdOutfield_, thresholdNewTransfer_, under21Age_);
        emit Events.EligibilityThresholdsUpdated(
            thresholdGk_, thresholdUnder21_, thresholdOutfield_, thresholdNewTransfer_, under21Age_
        );
    }

    function _applyThresholds(
        uint32 thresholdGk_,
        uint32 thresholdUnder21_,
        uint32 thresholdOutfield_,
        uint32 thresholdNewTransfer_,
        uint256 under21Age_
    ) private {
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
