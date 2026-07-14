// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { WAD } from "../types/AdvancedTradeTypes.sol";

/**
 * @title GapMath
 * @notice FMV liquidity-gap helpers for FundingController (share identity, not price).
 */
library GapMath {
    /// @notice g = (L* − liq) / L* in WAD, with L* = (ppm / PPM) * LIQ.
    function computeGap(uint256 ppm, uint256 PPM, uint256 liq, uint256 LIQ)
        internal
        pure
        returns (int256 gapWad)
    {
        if (PPM == 0 || LIQ == 0 || ppm == 0) return 0;
        uint256 target = (ppm * LIQ) / PPM; // L*
        if (target == 0) return 0;
        if (target >= liq) {
            gapWad = int256(((target - liq) * WAD) / target);
        } else {
            gapWad = -int256(((liq - target) * WAD) / target);
        }
    }

    function clamp(int256 gapWad, uint256 gMaxWad) internal pure returns (int256) {
        int256 maxG = int256(gMaxWad);
        if (gapWad > maxG) return maxG;
        if (gapWad < -maxG) return -maxG;
        return gapWad;
    }

    function abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    /// @notice Score = |g| if outside deadband, else 0.
    function score(int256 gapWad, uint256 gDeadWad) internal pure returns (uint256) {
        uint256 a = abs(gapWad);
        return a > gDeadWad ? a : 0;
    }
}
