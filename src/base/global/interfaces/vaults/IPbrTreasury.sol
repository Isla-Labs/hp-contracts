// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundState, RoundStatus } from "@types/vaults/VaultTypes.sol";

/**
 * @title IPbrTreasury
 * @notice Cross-contract surface for single-tournament PBR pots.
 * @dev Crank: `lockVaults` → `requestSettle` → `applyFixtureSettlement`* → Claimable.
 */
interface IPbrTreasury {
    function syncRegisterVault(address vault_) external;

    function syncUnregisterVault(address vault_) external;

    /// @notice Update live utilization. Call on 0↔nonzero only; `lockVaults` freezes the live set.
    function syncUtilization(bool utilized_) external;

    /// @notice Freeze `R`, `lockBlock`, and a snapshot of live-utilized vaults for the active round.
    function lockVaults() external;

    function requestSettle() external returns (bytes32[] memory requestIds_);

    function applyFixtureSettlement(
        bytes32 fixtureId_,
        bytes32 fixtureDigest_,
        address[] calldata vaults_,
        uint256[] calldata mwPoints_
    ) external returns (bool done_);

    /// @notice Vault-only payout; returns 0 if nothing owed. Loads `s`/`S` at `lockBlock`.
    function payClaim(uint16 seasonStartYear_, uint32 roundNumber_, address user_) external returns (uint256 payout_);

    function tournamentId() external view returns (bytes32);

    function isVault(address vault_) external view returns (bool);

    function getRound(uint16 seasonStartYear_, uint32 roundNumber_) external view returns (RoundState memory);

    /// @notice Lean read for claim / lock scans (status + lockBlock only).
    function getRoundClaimMeta(
        uint16 seasonStartYear_,
        uint32 roundNumber_
    ) external view returns (RoundStatus status_, uint64 lockBlock_);

    /// @notice True when this vault has a non-zero share of the round pot (`R > 0` and `m > 0`).
    function hasPayableVaultShare(
        uint16 seasonStartYear_,
        uint32 roundNumber_,
        address vault_
    ) external view returns (bool);

    function getVaultPoints(
        uint16 seasonStartYear_,
        uint32 roundNumber_,
        address vault_
    ) external view returns (uint256);

    function getVaults() external view returns (address[] memory);

    function getUtilizedVaults(uint16 seasonStartYear_, uint32 roundNumber_) external view returns (address[] memory);

    function getLiveUtilizedVaults() external view returns (address[] memory);

    function getCursors() external view returns (uint16 seasonStartYear_, uint32 active_, uint32 trading_);
}
