// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title MarkMath
 * @notice Discrete EMA update toward a spot observation.
 */
library MarkMath {
    /// @notice EMA step: mark ← mark + (spot − mark) * dt / (halfLife + dt).
    /// @dev halfLife in seconds (launch: 5 minutes). First observation seeds mark = spot.
    function emaUpdate(uint256 mark, uint256 spot, uint256 dt, uint256 halfLife)
        internal
        pure
        returns (uint256)
    {
        if (mark == 0) return spot;
        if (dt == 0 || halfLife == 0) return mark;
        uint256 alphaNum = dt;
        uint256 alphaDen = halfLife + dt;
        if (spot >= mark) {
            return mark + ((spot - mark) * alphaNum) / alphaDen;
        }
        return mark - ((mark - spot) * alphaNum) / alphaDen;
    }

    function isSaneMark(uint256 mark) internal pure returns (bool) {
        return mark > 0 && mark < type(uint128).max;
    }
}
