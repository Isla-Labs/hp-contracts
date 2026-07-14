// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { MarginParams, WAD } from "../types/AdvancedTradeTypes.sol";

/**
 * @title MarginMath
 * @notice Short notional / equity / margin-requirement helpers (mark-denominated).
 * @dev Short equity = collateral + saleProceeds − buybackCost(mark).
 */
library MarginMath {
    function notional(uint256 size, uint256 mark) internal pure returns (uint256) {
        return (size * mark) / WAD;
    }

    function buybackCost(uint256 size, uint256 mark) internal pure returns (uint256) {
        return notional(size, mark);
    }

    function shortEquity(uint256 collateral, uint256 saleProceeds, uint256 size, uint256 mark)
        internal
        pure
        returns (int256)
    {
        uint256 cost = buybackCost(size, mark);
        uint256 assets = collateral + saleProceeds;
        if (assets >= cost) return int256(assets - cost);
        return -int256(cost - assets);
    }

    function requiredMargin(uint256 size, uint256 mark, uint256 marginWad) internal pure returns (uint256) {
        return (notional(size, mark) * marginWad) / WAD;
    }

    /// @notice Equity after adverse close impact of `maxCloseImpactWad` on buyback cost.
    function equityAfterImpact(
        uint256 collateral,
        uint256 saleProceeds,
        uint256 size,
        uint256 mark,
        uint256 maxCloseImpactWad
    ) internal pure returns (int256) {
        uint256 cost = (buybackCost(size, mark) * (WAD + maxCloseImpactWad)) / WAD;
        uint256 assets = collateral + saleProceeds;
        if (assets >= cost) return int256(assets - cost);
        return -int256(cost - assets);
    }

    function meetsInitialMargin(
        uint256 collateral,
        uint256 saleProceeds,
        uint256 size,
        uint256 mark,
        MarginParams memory m
    ) internal pure returns (bool) {
        return meetsInitialMarginWithImpact(collateral, saleProceeds, size, mark, m, m.maxCloseImpactWad);
    }

    function meetsInitialMarginWithImpact(
        uint256 collateral,
        uint256 saleProceeds,
        uint256 size,
        uint256 mark,
        MarginParams memory m,
        uint256 closeImpactWad
    ) internal pure returns (bool) {
        int256 eq = equityAfterImpact(collateral, saleProceeds, size, mark, closeImpactWad);
        uint256 need = requiredMargin(size, mark, m.initialMarginWad);
        return eq >= int256(need);
    }

    function belowMaintenance(
        uint256 collateral,
        uint256 saleProceeds,
        uint256 size,
        uint256 mark,
        MarginParams memory m
    ) internal pure returns (bool) {
        int256 eq = shortEquity(collateral, saleProceeds, size, mark);
        uint256 need = requiredMargin(size, mark, m.maintenanceMarginWad);
        return eq < int256(need);
    }
}
