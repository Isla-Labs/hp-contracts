// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IImpactEstimator
 * @notice Optional pool-depth impact model for short open solvency (§3.5 / §3.6 max close-impact).
 * @dev When unset, vault falls back to `margins.maxCloseImpactWad` haircut in MarginMath.
 */
interface IImpactEstimator {
    /// @notice Estimated buyback price impact for selling/buying `size` player tokens, in WAD (e.g. 0.02e18 = 2%).
    function estimateCloseImpactWad(address playerToken, uint256 size) external view returns (uint256 impactWad);
}
