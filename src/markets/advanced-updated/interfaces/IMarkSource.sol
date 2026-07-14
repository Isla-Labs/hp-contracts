// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IMarkSource
 * @notice Spot price feed for AdvancedTradeVault EMA marks.
 * @dev Returns collateral units (USDC wei) per 1e18 player tokens, scaled to 1e18 precision
 *      when collateral has 18 decimals. With 6-decimal USDC, return USDC-wei * 1e12 per token ether
 *      so vault math `size * mark / 1e18` yields collateral wei — or use 18-decimal mock collateral
 *      in tests. Production wiring should normalize decimals explicitly.
 */
interface IMarkSource {
    /// @notice Current pool/oracle spot in WAD-compatible collateral-per-token units.
    function spotPriceWad() external view returns (uint256);
}
