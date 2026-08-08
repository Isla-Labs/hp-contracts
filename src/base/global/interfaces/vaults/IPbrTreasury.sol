// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundState } from "@types/vaults/VaultTypes.sol";

/**
 * @title IPbrTreasury
 * @notice Cross-contract surface for single-tournament PBR pots.
 * @dev Crank: `lock` → `snapshotBatch` → `requestSettle` (per-fixture zk) → `applyFixtureSettlement`*
 *      → Claimable. Claims read `vaultPoints` (simple `claim` / `claimAll`).
 */
interface IPbrTreasury {
    function syncRegisterVault(address vault) external;

    function syncUnregisterVault(address vault) external;

    function lock() external;

    function snapshotBatch() external returns (uint256 processed, bool done);

    function requestSettle() external returns (bytes32[] memory requestIds);

    /**
     * @notice Apply one fixture's zk-proven scores (≤32). Opens Claimable when all fixtures land.
     * @dev `PbrSettle` only.
     */
    function applyFixtureSettlement(
        bytes32 fixtureId,
        bytes32 fixtureDigest,
        address[] calldata vaults,
        uint256[] calldata mwPoints
    ) external returns (bool done);

    function payClaim(
        uint16 season,
        uint32 roundNumber,
        address user,
        uint256 s,
        uint256 S
    ) external returns (uint256 payout);

    function tournamentId() external view returns (bytes32);

    function isVault(address vault) external view returns (bool);

    function getRound(uint16 season, uint32 roundNumber) external view returns (RoundState memory);

    function getVaultPoints(uint16 season, uint32 roundNumber, address vault) external view returns (uint256);

    function getVaults() external view returns (address[] memory);

    function getUtilizedVaults(uint16 season, uint32 roundNumber) external view returns (address[] memory);

    function getCursors() external view returns (uint16 season, uint32 active, uint32 trading);

    function previewClaim(
        uint16 season,
        uint32 roundNumber,
        address vault,
        uint256 s,
        uint256 S
    ) external view returns (uint256 payout);
}
