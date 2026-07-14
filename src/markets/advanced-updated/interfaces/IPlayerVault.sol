// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IPlayerVault
 * @notice Minimal stake surface for AdvancedTrade ↔ PlayerVault incentive exclusivity (§3.7.6).
 */
interface IPlayerVault {
    /// @notice Player-token amount currently staked by `account` in this vault (0 if none).
    function stakedBalance(address account) external view returns (uint256);
}
