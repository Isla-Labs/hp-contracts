// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BorrowCurve, WAD } from "../types/AdvancedTradeTypes.sol";

/**
 * @title BorrowMath
 * @notice Two-slope utilization borrow APR and index accrual helpers.
 */
library BorrowMath {
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @notice Instantaneous borrow APR (WAD) from utilization `u` (WAD) and curve params.
    function borrowApr(uint256 u, BorrowCurve memory c) internal pure returns (uint256) {
        if (u <= c.uKink) {
            return c.r0 + (c.slope1 * u) / WAD;
        }
        uint256 atKink = c.r0 + (c.slope1 * c.uKink) / WAD;
        return atKink + (c.slope2 * (u - c.uKink)) / WAD;
    }

    /// @notice Accrue `index` forward by `dt` seconds at APR `apr` (WAD).
    function accrueIndex(uint256 index, uint256 apr, uint256 dt) internal pure returns (uint256) {
        if (dt == 0 || apr == 0) return index;
        // index * (1 + apr * dt / year)
        uint256 growth = (apr * dt) / SECONDS_PER_YEAR;
        return index + (index * growth) / WAD;
    }

    /// @notice Fee owed on `notional` between `indexBefore` and `indexAfter`.
    function feeOnNotional(uint256 notional, uint256 indexBefore, uint256 indexAfter)
        internal
        pure
        returns (uint256)
    {
        if (indexAfter <= indexBefore || notional == 0) return 0;
        return (notional * (indexAfter - indexBefore)) / WAD;
    }
}
