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

    /// @notice Vault push of live `S`. Returns target round; `joined_` if newly utilized.
    function syncVaultStake(uint256 newTotalStaked_)
        external
        returns (uint16 seasonStartYear_, uint32 roundNumber_, bool joined_);

    /// @notice Freeze `R` + `lockBlock` + utilized set for the active round (O(1)).
    function lockVaults() external;

    function requestSettle() external returns (bytes32[] memory requestIds_);

    function applyFixtureSettlement(
        bytes32 fixtureId_,
        bytes32 fixtureDigest_,
        address[] calldata vaults_,
        uint256[] calldata mwPoints_
    ) external returns (bool done_);

    /// @notice Vault-only payout; loads `s`/`S` from caller vault stToken at `lockBlock`.
    function payClaim(uint16 seasonStartYear_, uint32 roundNumber_, address user_) external returns (uint256 payout_);

    function tournamentId() external view returns (bytes32);

    function isVault(address vault_) external view returns (bool);

    function getRound(uint16 seasonStartYear_, uint32 roundNumber_) external view returns (RoundState memory);

    /// @notice Lean read for claim / lock scans (status + lockBlock only).
    function getRoundClaimMeta(
        uint16 seasonStartYear_,
        uint32 roundNumber_
    ) external view returns (RoundStatus status_, uint64 lockBlock_);

    function getVaultPoints(
        uint16 seasonStartYear_,
        uint32 roundNumber_,
        address vault_
    ) external view returns (uint256);

    function getVaults() external view returns (address[] memory);

    function getUtilizedVaults(uint16 seasonStartYear_, uint32 roundNumber_) external view returns (address[] memory);

    function getCursors() external view returns (uint16 seasonStartYear_, uint32 active_, uint32 trading_);

    function previewClaim(
        uint16 seasonStartYear_,
        uint32 roundNumber_,
        address vault_,
        address user_
    ) external view returns (uint256 payout_);
}
