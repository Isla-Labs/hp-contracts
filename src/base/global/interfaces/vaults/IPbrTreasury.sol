// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundState } from "@types/vaults/VaultTypes.sol";

/**
 * @title IPbrTreasury
 * @notice Cross-contract surface for single-tournament PBR pots.
 * @dev Vault membership SoT is `TournamentRegistry`; this contract holds a local cache
 *      updated only via `syncRegisterVault` / `syncUnregisterVault` from the registry.
 */
interface IPbrTreasury {
    // --------------------------------------------
    //  Vault cache sync — TournamentRegistry only
    // --------------------------------------------

    function syncRegisterVault(address vault) external;

    function syncUnregisterVault(address vault) external;

    // --------------------------------------------
    //  Settlement — owner (Orchestrator) or PbrSettle
    // --------------------------------------------

    function settle(address[] calldata vaults, uint256[] calldata mwPoints, uint256 adjTotalPoints) external;

    // --------------------------------------------
    //  Claims (called by PlayerVault)
    // --------------------------------------------

    function payClaim(
        uint16 season,
        uint32 roundNumber,
        address user,
        uint256 s,
        uint256 S
    ) external returns (uint256 payout);

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function tournamentId() external view returns (bytes32);

    function isVault(address vault) external view returns (bool);

    function getRound(uint16 season, uint32 roundNumber) external view returns (RoundState memory);

    function getVaultPoints(uint16 season, uint32 roundNumber, address vault) external view returns (uint256);

    function getVaults() external view returns (address[] memory);

    function getCursors() external view returns (uint16 season, uint32 active, uint32 trading);

    function previewClaim(
        uint16 season,
        uint32 roundNumber,
        address vault,
        uint256 s,
        uint256 S
    ) external view returns (uint256 payout);
}
