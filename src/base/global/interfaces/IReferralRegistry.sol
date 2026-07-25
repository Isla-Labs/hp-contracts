// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IReferralRegistry
 * @notice Account → referral boost factor for vault PBR weight math.
 * @dev `boostBps` is in basis points with base 10_000 (e.g. 11_000 = +10%).
 *      Tier / qualification indexing is owned by this registry; vaults only read BPS.
 *      When `boostsEnabled` is false, `boostBps` returns 10_000 for every account.
 */
interface IReferralRegistry {
    /// @notice Global kill switch; when false, all `boostBps` reads return 10_000.
    function boostsEnabled() external view returns (bool);

    /// @notice Effective boost factor for `account` in BPS (10_000 = 1.0×, max 11_000).
    function boostBps(address account) external view returns (uint16);

    /// @notice Referral tier 0–10 (each step = +1% boost). Unaffected by the kill switch.
    function tierOf(address account) external view returns (uint8);
}
