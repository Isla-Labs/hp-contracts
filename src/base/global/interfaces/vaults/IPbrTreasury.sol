// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundState } from "@types/vaults/VaultTypes.sol";

/**
 * @title IPbrTreasury
 * @notice Cross-contract surface for single-tournament PBR pots.
 * @dev Crank: `lockVaults` → `requestSettle` → `applyFixtureSettlement`* → Claimable.
 */
interface IPbrTreasury {
    function syncRegisterVault(address vault) external;

    function syncUnregisterVault(address vault) external;

    /// @notice Vault push of live `S`. Returns target round; `joined` if newly utilized.
    function syncVaultStake(uint256 newTotalStaked) external returns (uint16 season, uint32 roundNumber, bool joined);

    /// @notice Freeze `R` + `lockBlock` + utilized set for the active round (O(1)).
    function lockVaults() external;

    function requestSettle() external returns (bytes32[] memory requestIds);

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
