// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PoolKey } from "@v4-core/types/PoolKey.sol";

import {
    AdvancedTradeData,
    DopplerData,
    PlayerSet,
    PlayerStatus,
    TokenData,
    TournamentData,
    VaultData
} from "@types/registries/PlayerSetTypes.sol";

/**
 * @title IPlayerSetRegistry
 * @notice Cross-contract surface for per-player market discovery sets.
 */
interface IPlayerSetRegistry {
    // --------------------------------------------
    //  Registration — owner (Orchestrator)
    // --------------------------------------------

    function addPlayerSet(
        bytes32 playerId,
        TokenData calldata tokenData,
        TournamentData calldata tournamentData,
        DopplerData calldata dopplerData,
        VaultData calldata vaultData
    ) external;

    function addAdvancedTradeData(bytes32 playerId, AdvancedTradeData calldata data) external;

    // --------------------------------------------
    //  Status lifecycle — owner (Orchestrator)
    // --------------------------------------------

    /**
     * @notice Bonding → graduated: write migrated `activePool` + `GRADUATED`.
     * @dev Mirrors status onto FeeRouter (fee split). No vault / tournament membership fan-out.
     */
    function graduatePool(bytes32 playerId, PoolKey calldata activePool) external;

    /**
     * @notice Soft-inactive: `INACTIVE` + FeeRouter / vault / unregister + clear discovery topology.
     */
    function deactivate(bytes32 playerId) external;

    /**
     * @notice Restore from `INACTIVE`: status from `activePool.hooks` + FeeRouter / vault / register.
     * @dev Caller should restore `leagueId` / `activeTournaments` via `setLeagueId` first when cleared.
     */
    function reactivate(bytes32 playerId) external;

    // --------------------------------------------
    //  Upkeep
    // --------------------------------------------

    function updateUtilization(bool isUtilized) external;

    /**
     * @notice Remap domestic league (ChangedLeague / oracle fulfill).
     * @dev Unregisters vault from current pots (via TR), sets `leagueId` + FeeRouter hub, then
     *      registers `activeTournamentIds` via TR. PSR `activeTournaments` is mirrored by TR only.
     *      `activeTournamentIds` must be non-empty and include `newLeagueId`.
     */
    function setLeagueId(bytes32 playerId, bytes32 newLeagueId, bytes32[] calldata activeTournamentIds) external;

    /**
     * @notice Mirror: add `tournamentId` to the player's discovery index.
     * @dev Callable only by `TournamentRegistry` when the membership caller is not PSR. Idempotent.
     */
    function addActiveTournament(bytes32 playerId, bytes32 tournamentId) external;

    /**
     * @notice Mirror: remove `tournamentId` from the player's discovery index.
     * @dev Callable only by `TournamentRegistry` when the membership caller is not PSR
     *      (e.g. owner batch / flush). Idempotent.
     */
    function removeActiveTournament(bytes32 playerId, bytes32 tournamentId) external;

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
