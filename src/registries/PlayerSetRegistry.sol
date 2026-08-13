// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { RegistryErrors as Errors } from "@errors/registries/RegistryErrors.sol";
import { RegistryEvents as Events } from "@events/registries/RegistryEvents.sol";
import {
    AdvancedTradeData,
    DopplerData,
    PlayerSet,
    PlayerStatus,
    TokenData,
    TournamentData,
    VaultData
} from "@types/registries/PlayerSetTypes.sol";
import { IPlayerSetRegistry } from "@interfaces/registries/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@interfaces/registries/ITournamentRegistry.sol";
import { IFeeRouter } from "@interfaces/markets/IFeeRouter.sol";
import { IPlayerVault } from "@interfaces/vaults/IPlayerVault.sol";

/**
 * @title PlayerSetRegistry
 * @notice Canonical per-player market discovery set (`playerId` → `PlayerSet`).
 * @dev Access (AddressProvider; no Ownable / initialize):
 *      - `MARKET_INITIALIZER`: `addPlayerSet` (market deploy).
 *      - `LIFECYCLE_MANAGER`: `deactivate` / `reactivate` / `setLeagueId`.
 *      - `MIGRATION_LISTENER`: `graduatePool`.
 *      - `ORCHESTRATOR`: AT attach.
 *      - `TOURNAMENT_REGISTRY`: `add`/`removeActiveTournament` mirror (when TR caller ≠ PSR).
 *      - Vault membership SoT is `TournamentRegistry`. PSR-driven lifecycle updates
 *        `activeTournaments` itself (no PSR→TR→PSR).
 *      - `deactivate` / `reactivate` / `setLeagueId` fan out TR membership + FeeRouter +
 *        `PlayerVault.setActive`.
 *      - Registered vaults: `updateUtilization` via `onlyVault`.
 *      - Doppler hook addresses + feeRouter are immutable after `addPlayerSet`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerSetRegistry is AddressBook, IPlayerSetRegistry {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    mapping(bytes32 playerId => PlayerSet) private _playerSets;
    mapping(address token => bytes32 playerId) public playerIdOfToken;
    mapping(address vault => bytes32 playerId) public playerIdOfVault;

    bytes32[] private _playerIds;

    // --------------------------------------------
    //  Access Control
    // --------------------------------------------

    modifier onlyVault() {
        if (playerIdOfVault[msg.sender] == bytes32(0)) revert Errors.NotAuthorized();
        _;
    }

    modifier onlyOrchestrator() {
        if (msg.sender != _getAddress(_addressKey(Addresses.ORCHESTRATOR))) revert Errors.NotAuthorized();
        _;
    }

    modifier onlyMarketInitializer() {
        if (msg.sender != _getAddress(_addressKey(Addresses.MARKET_INITIALIZER))) revert Errors.NotAuthorized();
        _;
    }

    modifier onlyLifecycleManager() {
        if (msg.sender != _getAddress(_addressKey(Addresses.LIFECYCLE_MANAGER))) revert Errors.NotAuthorized();
        _;
    }

    modifier onlyMigrationListener() {
        if (msg.sender != _getAddress(_addressKey(Addresses.MIGRATION_LISTENER))) revert Errors.NotAuthorized();
        _;
    }

    modifier onlyTournamentRegistry() {
        if (msg.sender != _getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY))) revert Errors.NotAuthorized();
        _;
    }

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    constructor(address addressProvider_) AddressBook(addressProvider_) { }

    // --------------------------------------------
    //  Registration
    // --------------------------------------------

    /**
     * @notice Registers a full player market set (token, tournaments, Doppler, vault).
     * @dev Advanced Trade is attached later via `addAdvancedTradeData`.
     */
    function addPlayerSet(
        bytes32 playerId,
        TokenData calldata tokenData,
        TournamentData calldata tournamentData,
        DopplerData calldata dopplerData,
        VaultData calldata vaultData
    ) external onlyMarketInitializer {
        if (playerId == bytes32(0)) revert Errors.ZeroId();
        if (tokenData.token == address(0)) revert Errors.ZeroAddress();
        if (
            dopplerData.hookDoppler == address(0) || dopplerData.hookMigrator == address(0)
                || dopplerData.feeRouter == address(0)
        ) {
            revert Errors.ZeroAddress();
        }
        if (vaultData.playerVault == address(0) || vaultData.stToken == address(0)) revert Errors.ZeroAddress();
        if (_playerSets[playerId].tokenData.token != address(0)) revert Errors.Exists();
        if (playerIdOfToken[tokenData.token] != bytes32(0)) revert Errors.Exists();
        if (playerIdOfVault[vaultData.playerVault] != bytes32(0)) revert Errors.Exists();

        PlayerSet storage set = _playerSets[playerId];
        set.status = PlayerStatus.BONDING;
        set.tokenData = tokenData;
        set.dopplerData = dopplerData;
        set.vaultData = VaultData({
            playerVault: vaultData.playerVault, stToken: vaultData.stToken, isUtilized: vaultData.isUtilized
        });
        _writeTournamentData(set, tournamentData);

        playerIdOfToken[tokenData.token] = playerId;
        playerIdOfVault[vaultData.playerVault] = playerId;
        _playerIds.push(playerId);

        emit Events.PlayerRegistered(playerId, tokenData.token, dopplerData.feeRouter);
        emit Events.VaultDataAdded(playerId, vaultData.playerVault, vaultData.stToken);
        if (tournamentData.leagueId != bytes32(0)) emit Events.LeagueIdUpdated(playerId, tournamentData.leagueId);

        uint256 n = tournamentData.activeTournaments.length;
        for (uint256 i; i < n; ++i) {
            emit Events.ActiveTournamentAdded(playerId, tournamentData.activeTournaments[i]);
        }
    }

    /**
     * @notice Attaches Advanced Trade vault + mark source after those deployments.
     */
    function addAdvancedTradeData(bytes32 playerId, AdvancedTradeData calldata data) external onlyMarketInitializer {
        PlayerSet storage set = _requirePlayer(playerId);
        if (set.advancedTradeData.advancedTradeVault != address(0)) {
            revert Errors.AdvancedTradeDataAlreadySet(playerId);
        }
        if (data.advancedTradeVault == address(0) || data.markSource == address(0)) revert Errors.ZeroAddress();

        set.advancedTradeData = data;
        emit Events.AdvancedTradeDataAdded(playerId, data.advancedTradeVault, data.markSource);
    }

    // --------------------------------------------
    //  Active tournaments (discovery index mirror)
    // --------------------------------------------

    /// @inheritdoc IPlayerSetRegistry
    function addActiveTournament(bytes32 playerId, bytes32 tournamentId) external onlyTournamentRegistry {
        _requirePlayer(playerId);
        if (tournamentId == bytes32(0)) revert Errors.ZeroId();
        _addActiveTournamentIfAbsent(playerId, tournamentId);
    }

    /// @inheritdoc IPlayerSetRegistry
    function removeActiveTournament(bytes32 playerId, bytes32 tournamentId) external onlyTournamentRegistry {
        _requirePlayer(playerId);
        if (tournamentId == bytes32(0)) revert Errors.ZeroId();
        _removeActiveTournamentIfPresent(playerId, tournamentId);
    }

    // --------------------------------------------
    //  Transfers
    // --------------------------------------------

    /**
     * @notice Remap domestic league (ChangedLeague oracle fulfill).
     * @dev Unregister current pots → write `leagueId` + FeeRouter hub → register oracle tournaments.
     *      Discovery index is updated here (TR skips mirror when caller is PSR).
     */
    function setLeagueId(
        bytes32 playerId,
        bytes32 newLeagueId,
        bytes32[] calldata activeTournamentIds
    ) external onlyLifecycleManager {
        if (newLeagueId == bytes32(0)) revert Errors.ZeroId();
        uint256 n = activeTournamentIds.length;
        if (n == 0) revert Errors.LengthMismatch();

        bool hasLeague;
        for (uint256 i; i < n; ++i) {
            bytes32 tournamentId = activeTournamentIds[i];
            if (tournamentId == bytes32(0)) revert Errors.ZeroId();
            for (uint256 j; j < i; ++j) {
                if (activeTournamentIds[j] == tournamentId) revert Errors.TournamentAlreadyActive(tournamentId);
            }
            if (tournamentId == newLeagueId) hasLeague = true;
        }
        if (!hasLeague) revert Errors.TournamentNotActive(newLeagueId);

        ITournamentRegistry tournamentRegistry =
            ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
        address hub = tournamentRegistry.pbrFeeHubOf(newLeagueId);
        if (hub == address(0)) revert Errors.HubNotRegistered(newLeagueId);

        PlayerSet storage set = _requirePlayer(playerId);
        address vault = set.vaultData.playerVault;
        address feeRouter = set.dopplerData.feeRouter;
        if (feeRouter == address(0)) revert Errors.ZeroAddress();

        // Leave current pots (snapshot vault active treasuries — safe under TR index mirrors).
        _unregisterVaultFromAll(vault);

        set.tournamentData.leagueId = newLeagueId;
        emit Events.LeagueIdUpdated(playerId, newLeagueId);
        IFeeRouter(feeRouter).setPbrFeeHub(hub);

        for (uint256 i; i < n; ++i) {
            _syncVaultOnTournament(activeTournamentIds[i], vault, true);
        }
    }

    // --------------------------------------------
    //  Lifecycle
    // --------------------------------------------

    function updateUtilization(bool isUtilized) external onlyVault {
        bytes32 playerId = playerIdOfVault[msg.sender];
        PlayerSet storage set = _playerSets[playerId];
        if (set.vaultData.playerVault != msg.sender) revert Errors.NotAuthorized();

        set.vaultData.isUtilized = isUtilized;
        emit Events.VaultDataUpdated(playerId, set.vaultData.playerVault, set.vaultData.stToken, isUtilized);
    }

    /**
     * @notice Bonding → graduated: migrated `activePool` + `GRADUATED`.
     * @dev Syncs FeeRouter status cache (spot integrator share). No vault / tournament fan-out.
     *      `activePool.hooks` must be the registered `hookMigrator`.
     */
    function graduatePool(bytes32 playerId, PoolKey calldata activePool) external onlyMigrationListener {
        PlayerSet storage set = _requirePlayer(playerId);
        if (address(activePool.hooks) != set.dopplerData.hookMigrator) {
            revert Errors.InvalidActivePool(playerId, address(activePool.hooks));
        }

        set.dopplerData.activePool = activePool;
        emit Events.ActivePoolUpdated(playerId);

        set.status = PlayerStatus.GRADUATED;
        emit Events.StatusUpdated(playerId, PlayerStatus.GRADUATED);

        address feeRouter = set.dopplerData.feeRouter;
        if (feeRouter != address(0)) {
            IFeeRouter(feeRouter).setStatus(PlayerStatus.GRADUATED);
        }
    }

    /**
     * @notice Soft-inactive path (LifecycleManager Continuity / LeftLeague).
     * @dev FeeRouter OOF, vault inactive, unregister (may defer while Locked), clear discovery topology.
     */
    function deactivate(bytes32 playerId) external onlyLifecycleManager {
        PlayerSet storage set = _requirePlayer(playerId);
        set.status = PlayerStatus.INACTIVE;
        emit Events.StatusUpdated(playerId, PlayerStatus.INACTIVE);

        address feeRouter = set.dopplerData.feeRouter;
        if (feeRouter != address(0)) {
            IFeeRouter(feeRouter).setStatus(PlayerStatus.INACTIVE);
        }

        address vault = set.vaultData.playerVault;
        if (vault != address(0)) {
            IPlayerVault(vault).setActive(false);
        }

        _unregisterVaultFromAll(vault);
        // Soft-inactive: empty discovery even if some unregisters are Locked-deferred on TR.
        _clearTournamentMembership(playerId, set);
    }

    /**
     * @notice Restore-from-INACTIVE (LifecycleManager Reactivate, after `setLeagueId`).
     * @dev Status derived from `activePool.hooks`. Membership already applied in `setLeagueId`.
     */
    function reactivate(bytes32 playerId) external onlyLifecycleManager {
        PlayerSet storage set = _requirePlayer(playerId);
        PlayerStatus status = _statusFromActivePool(playerId, set);

        set.status = status;
        emit Events.StatusUpdated(playerId, status);

        address feeRouter = set.dopplerData.feeRouter;
        if (feeRouter != address(0)) {
            IFeeRouter(feeRouter).setStatus(status);
        }

        address vault = set.vaultData.playerVault;
        if (vault != address(0)) {
            IPlayerVault(vault).setActive(true);
        }
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function getPlayerSet(bytes32 playerId) external view returns (PlayerSet memory) {
        _requirePlayer(playerId);
        return _playerSets[playerId];
    }

    function getTournamentData(bytes32 playerId) external view returns (TournamentData memory) {
        _requirePlayer(playerId);
        return _playerSets[playerId].tournamentData;
    }

    function getDopplerData(bytes32 playerId) external view returns (DopplerData memory) {
        _requirePlayer(playerId);
        return _playerSets[playerId].dopplerData;
    }

    function getVaultData(bytes32 playerId) external view returns (VaultData memory) {
        _requirePlayer(playerId);
        return _playerSets[playerId].vaultData;
    }

    function getAdvancedTradeData(bytes32 playerId) external view returns (AdvancedTradeData memory) {
        _requirePlayer(playerId);
        return _playerSets[playerId].advancedTradeData;
    }

    function playerExists(bytes32 playerId) external view returns (bool) {
        return _playerSets[playerId].tokenData.token != address(0);
    }

    function allPlayerIds() external view returns (bytes32[] memory) {
        return _playerIds;
    }

    function playerCount() external view returns (uint256) {
        return _playerIds.length;
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _writeTournamentData(PlayerSet storage set, TournamentData calldata tournamentData) internal {
        set.tournamentData.leagueId = tournamentData.leagueId;

        uint256 n = tournamentData.activeTournaments.length;
        for (uint256 i; i < n; ++i) {
            bytes32 tournamentId = tournamentData.activeTournaments[i];
            if (tournamentId == bytes32(0)) revert Errors.ZeroId();
            for (uint256 j; j < i; ++j) {
                if (tournamentData.activeTournaments[j] == tournamentId) {
                    revert Errors.TournamentAlreadyActive(tournamentId);
                }
            }
            set.tournamentData.activeTournaments.push(tournamentId);
        }
    }

    function _addActiveTournamentIfAbsent(bytes32 playerId, bytes32 tournamentId) internal {
        bytes32[] storage active = _playerSets[playerId].tournamentData.activeTournaments;
        uint256 length = active.length;
        for (uint256 i; i < length; ++i) {
            if (active[i] == tournamentId) return;
        }

        active.push(tournamentId);
        emit Events.ActiveTournamentAdded(playerId, tournamentId);
    }

    function _removeActiveTournamentIfPresent(bytes32 playerId, bytes32 tournamentId) internal {
        bytes32[] storage active = _playerSets[playerId].tournamentData.activeTournaments;
        uint256 length = active.length;
        uint256 index = type(uint256).max;
        for (uint256 i; i < length; ++i) {
            if (active[i] == tournamentId) {
                index = i;
                break;
            }
        }
        if (index == type(uint256).max) return;

        uint256 last = length - 1;
        if (index != last) active[index] = active[last];
        active.pop();
        emit Events.ActiveTournamentRemoved(playerId, tournamentId);
    }

    function _requirePlayer(bytes32 playerId) internal view returns (PlayerSet storage set) {
        set = _playerSets[playerId];
        if (set.tokenData.token == address(0)) revert Errors.NotFound();
    }

    /// @dev BONDING if initializer hooks; GRADUATED if migrator hooks.
    function _statusFromActivePool(bytes32 playerId, PlayerSet storage set) private view returns (PlayerStatus) {
        address hooks = address(set.dopplerData.activePool.hooks);
        if (hooks == set.dopplerData.hookDoppler) return PlayerStatus.BONDING;
        if (hooks == set.dopplerData.hookMigrator) return PlayerStatus.GRADUATED;
        revert Errors.InvalidActivePool(playerId, hooks);
    }

    /// @dev Empty discovery index after deactivate (vaults already unregistered).
    function _clearTournamentMembership(bytes32 playerId, PlayerSet storage set) private {
        bytes32[] storage active = set.tournamentData.activeTournaments;
        while (active.length != 0) {
            bytes32 removed = active[active.length - 1];
            active.pop();
            emit Events.ActiveTournamentRemoved(playerId, removed);
        }
        if (set.tournamentData.leagueId != bytes32(0)) {
            set.tournamentData.leagueId = bytes32(0);
            emit Events.LeagueIdUpdated(playerId, bytes32(0));
        }
    }

    /**
     * @dev Unregister `vault` from every tournament in its live `activeTreasuries` cache.
     *      Snapshot first — vault cache mutates during immediate unregisters.
     */
    function _unregisterVaultFromAll(address vault) private {
        if (vault == address(0)) return;

        IPlayerVault playerVault = IPlayerVault(vault);
        uint256 n = playerVault.activeTreasuryCount();
        bytes32[] memory tournamentIds = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            (tournamentIds[i],) = playerVault.activeTreasuryAt(i);
        }
        for (uint256 i; i < n; ++i) {
            bytes32 tournamentId = tournamentIds[i];
            if (tournamentId == bytes32(0)) continue;
            _syncVaultOnTournament(tournamentId, vault, false);
        }
    }

    /**
     * @dev TR membership write + local discovery index (TR skips mirror when we are the caller).
     *      Locked-deferred unregister leaves TR membership intact — index is left until flush
     *      (owner/treasury path mirrors) or `deactivate` clears discovery.
     */
    function _syncVaultOnTournament(bytes32 tournamentId, address vault, bool register) private {
        if (vault == address(0)) return;

        ITournamentRegistry tournamentRegistry =
            ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
        if (!tournamentRegistry.tournamentExists(tournamentId)) return;

        bytes32 playerId = playerIdOfVault[vault];
        if (playerId == bytes32(0)) return;

        bool registered = tournamentRegistry.isVaultRegistered(tournamentId, vault);
        if (register) {
            if (registered) return;
            address[] memory vaults = new address[](1);
            vaults[0] = vault;
            tournamentRegistry.registerVaults(tournamentId, vaults);
            _addActiveTournamentIfAbsent(playerId, tournamentId);
        } else {
            if (!registered) return;
            address[] memory vaults = new address[](1);
            vaults[0] = vault;
            tournamentRegistry.unregisterVaults(tournamentId, vaults);
            // Only drop the index when the vault actually left (not Locked-pending).
            if (!tournamentRegistry.isVaultRegistered(tournamentId, vault)) {
                _removeActiveTournamentIfPresent(playerId, tournamentId);
            }
        }
    }
}
