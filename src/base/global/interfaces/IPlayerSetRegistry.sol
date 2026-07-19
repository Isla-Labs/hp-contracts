// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import {
    AdvancedTradeData,
    DopplerData,
    PlayerSet,
    PlayerStatus,
    TokenData,
    TournamentData,
    VaultData
} from "@base/global/types/PlayerSetTypes.sol";

/**
 * @title IPlayerSetRegistry
 * @notice Cross-contract surface for per-player market discovery sets.
 */
interface IPlayerSetRegistry {
    // --------------------------------------------
    //  Registration — CATEGORY_THREE
    // --------------------------------------------

    function addPlayerSet(
        bytes32 playerId,
        TokenData calldata tokenData,
        TournamentData calldata tournamentData,
        DopplerData calldata dopplerData
    ) external;

    function addVaultData(bytes32 playerId, VaultData calldata vaultData) external;

    function addAdvancedTradeData(bytes32 playerId, AdvancedTradeData calldata data) external;

    function setDopplerData(bytes32 playerId, DopplerData calldata data) external;

    // --------------------------------------------
    //  Upkeep
    // --------------------------------------------

    function updateUtilization(bool isUtilized) external;

    function setStatus(bytes32 playerId, PlayerStatus status) external;

    function setLeagueId(bytes32 playerId, bytes32 leagueId) external;

    function addActiveTournament(bytes32 playerId, bytes32 tournamentId) external;

    function removeActiveTournament(bytes32 playerId, bytes32 tournamentId) external;

    /// @notice Called by the tournament's `PbrTreasury` after registering a vault.
    function addActiveTournamentForVault(address vault, bytes32 tournamentId) external;

    /// @notice Called by the tournament's `PbrTreasury` after unregistering a vault.
    function removeActiveTournamentForVault(address vault, bytes32 tournamentId) external;

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function playerIdOfToken(address token) external view returns (bytes32);

    function playerIdOfVault(address vault) external view returns (bytes32);

    function getPlayerSet(bytes32 playerId) external view returns (PlayerSet memory);

    function getTournamentData(bytes32 playerId) external view returns (TournamentData memory);

    function getDopplerData(bytes32 playerId) external view returns (DopplerData memory);

    function getVaultData(bytes32 playerId) external view returns (VaultData memory);

    function getAdvancedTradeData(bytes32 playerId) external view returns (AdvancedTradeData memory);

    function playerExists(bytes32 playerId) external view returns (bool);

    function allPlayerIds() external view returns (bytes32[] memory);

    function playerCount() external view returns (uint256);
}
