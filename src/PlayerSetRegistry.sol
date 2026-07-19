// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AccessRoles as Roles } from "@base/global/libraries/roles/AccessRoles.sol";
import { RegistryErrors as Errors } from "@base/global/libraries/errors/RegistryErrors.sol";
import { RegistryEvents as Events } from "@base/global/libraries/events/RegistryEvents.sol";
import {
    AdvancedTradeData,
    DopplerData,
    PlayerSet,
    PlayerStatus,
    TokenData,
    TournamentData,
    VaultData
} from "@base/global/types/PlayerSetTypes.sol";
import { IPlayerSetRegistry } from "@base/global/interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@base/global/interfaces/ITournamentRegistry.sol";

/**
 * @title PlayerSetRegistry
 * @notice Canonical per-player market discovery set (`playerId` → `PlayerSet`).
 * @dev Access:
 *      - `CATEGORY_THREE` (`Automator` / `DeployTournament`): registration, status, league /
 *        active tournaments, and Doppler updates.
 *      - Tournament `PbrTreasury`: `addActiveTournamentForVault` / `removeActiveTournamentForVault`
 *        (keeps discovery in sync with treasury vault registration).
 *      - Registered vaults: `updateUtilization` via `onlyVault`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerSetRegistry is Initializable, AccessControl, IPlayerSetRegistry {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    ITournamentRegistry public immutable tournamentRegistry;

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

    /// @dev Automator (cat-3) or MaintenanceTimelock (cat-2) for vault registry repairs.
    modifier onlyCategoryTwoOrThree() {
        address sender = _msgSender();
        if (!hasRole(Roles.CATEGORY_TWO, sender) && !hasRole(Roles.CATEGORY_THREE, sender)) {
            revert Errors.NotAuthorized();
        }
        _;
    }

    /// @dev Canonical `PbrTreasury` for `tournamentId` (from `TournamentRegistry`).
    modifier onlyTournamentTreasury(bytes32 tournamentId) {
        address treasury = tournamentRegistry.getPbrTreasury(tournamentId);
        if (treasury == address(0) || msg.sender != treasury) revert Errors.NotAuthorized();
        _;
    }

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address tournamentRegistry_) {
        if (tournamentRegistry_ == address(0)) revert Errors.ZeroAddress();
        tournamentRegistry = ITournamentRegistry(tournamentRegistry_);
        _disableInitializers();
    }

    /**
     * @param automator_ `Automator` — `CATEGORY_THREE`.
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE`.
     */
    function initialize(address automator_, address dao_) external initializer {
        if (automator_ == address(0) || dao_ == address(0)) revert Errors.ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_THREE, automator_);
    }

    // --------------------------------------------
    //  Registration (CATEGORY_THREE)
    // --------------------------------------------

    /**
     * @notice Registers a new player with token, tournament, and Doppler market data.
     * @dev Vault / advanced-trade sets are added separately after those deployments.
     */
    function addPlayerSet(
        bytes32 playerId,
        TokenData calldata tokenData,
        TournamentData calldata tournamentData,
        DopplerData calldata dopplerData
    ) external onlyRole(Roles.CATEGORY_THREE) {
        if (playerId == bytes32(0)) revert Errors.ZeroId();
        if (tokenData.token == address(0)) revert Errors.ZeroAddress();
        if (
            dopplerData.hookDoppler == address(0) || dopplerData.hookMigrator == address(0)
                || dopplerData.feeRouter == address(0)
        ) {
            revert Errors.ZeroAddress();
        }
        if (_playerSets[playerId].tokenData.token != address(0)) revert Errors.Exists();
        if (playerIdOfToken[tokenData.token] != bytes32(0)) revert Errors.Exists();

        PlayerSet storage set = _playerSets[playerId];
        set.status = PlayerStatus.BONDING;
        set.tokenData = tokenData;
        set.dopplerData = dopplerData;
        _writeTournamentData(set, tournamentData);

        playerIdOfToken[tokenData.token] = playerId;
        _playerIds.push(playerId);

        emit Events.PlayerRegistered(playerId, tokenData.token, dopplerData.feeRouter);
        if (tournamentData.leagueId != bytes32(0)) emit Events.LeagueIdUpdated(playerId, tournamentData.leagueId);

        uint256 n = tournamentData.activeTournaments.length;
        for (uint256 i; i < n; ++i) {
            emit Events.ActiveTournamentAdded(playerId, tournamentData.activeTournaments[i]);
        }
    }

    /**
     * @notice Attaches vault + stToken after `PlayerVault` deployment.
     */
    function addVaultData(bytes32 playerId, VaultData calldata vaultData) external onlyRole(Roles.CATEGORY_THREE) {
        PlayerSet storage set = _requirePlayer(playerId);
        if (set.vaultData.playerVault != address(0)) revert Errors.VaultDataAlreadySet(playerId);
        if (vaultData.playerVault == address(0) || vaultData.stToken == address(0)) revert Errors.ZeroAddress();
        if (playerIdOfVault[vaultData.playerVault] != bytes32(0)) revert Errors.Exists();

        set.vaultData = VaultData({
            playerVault: vaultData.playerVault, stToken: vaultData.stToken, isUtilized: vaultData.isUtilized
        });
        playerIdOfVault[vaultData.playerVault] = playerId;

        emit Events.VaultDataAdded(playerId, vaultData.playerVault, vaultData.stToken);
    }

    /**
     * @notice Attaches Advanced Trade vault + mark source after those deployments.
     */
    function addAdvancedTradeData(bytes32 playerId, AdvancedTradeData calldata data)
        external
        onlyRole(Roles.CATEGORY_THREE)
    {
        PlayerSet storage set = _requirePlayer(playerId);
        if (set.advancedTradeData.advancedTradeVault != address(0)) revert Errors.AdvancedTradeDataAlreadySet(playerId);
        if (data.advancedTradeVault == address(0) || data.markSource == address(0)) revert Errors.ZeroAddress();

        set.advancedTradeData = data;
        emit Events.AdvancedTradeDataAdded(playerId, data.advancedTradeVault, data.markSource);
    }

    /// @notice Updates Doppler fields after migration / hook replacement
    function setDopplerData(bytes32 playerId, DopplerData calldata data) external onlyRole(Roles.CATEGORY_THREE) {
        _requirePlayer(playerId);
        if (data.hookDoppler == address(0) || data.hookMigrator == address(0) || data.feeRouter == address(0)) {
            revert Errors.ZeroAddress();
        }
        _playerSets[playerId].dopplerData = data;
        emit Events.DopplerDataUpdated(playerId, data.feeRouter);
    }

    // --------------------------------------------
    //  Upkeep
    // --------------------------------------------

    function updateUtilization(bool isUtilized) external onlyVault {
        bytes32 playerId = playerIdOfVault[msg.sender];
        PlayerSet storage set = _playerSets[playerId];
        if (set.vaultData.playerVault != msg.sender) revert Errors.NotAuthorized();

        set.vaultData.isUtilized = isUtilized;
        emit Events.VaultDataUpdated(playerId, set.vaultData.playerVault, set.vaultData.stToken, isUtilized);
    }

    function setStatus(bytes32 playerId, PlayerStatus status) external onlyCategoryTwoOrThree {
        _requirePlayer(playerId);
        _playerSets[playerId].status = status;
        emit Events.StatusUpdated(playerId, status);
    }

    function setLeagueId(bytes32 playerId, bytes32 leagueId) external onlyCategoryTwoOrThree {
        _requirePlayer(playerId);
        _playerSets[playerId].tournamentData.leagueId = leagueId;
        emit Events.LeagueIdUpdated(playerId, leagueId);
    }

    function addActiveTournament(bytes32 playerId, bytes32 tournamentId) external onlyCategoryTwoOrThree {
        _requirePlayer(playerId);
        _addActiveTournament(playerId, tournamentId);
    }

    function removeActiveTournament(bytes32 playerId, bytes32 tournamentId) external onlyCategoryTwoOrThree {
        _requirePlayer(playerId);
        _removeActiveTournament(playerId, tournamentId);
    }

    /**
     * @notice Sync path for `PbrTreasury.registerVault(s)` — marks `tournamentId` active for the vault's player.
     * @dev `msg.sender` must be `TournamentRegistry.getPbrTreasury(tournamentId)`.
     */
    function addActiveTournamentForVault(address vault, bytes32 tournamentId)
        external
        onlyTournamentTreasury(tournamentId)
    {
        bytes32 playerId = playerIdOfVault[vault];
        if (playerId == bytes32(0)) revert Errors.NotFound();
        _addActiveTournament(playerId, tournamentId);
    }

    /**
     * @notice Sync path for `PbrTreasury.unregisterVault(s)` — clears `tournamentId` for the vault's player.
     * @dev `msg.sender` must be `TournamentRegistry.getPbrTreasury(tournamentId)`.
     */
    function removeActiveTournamentForVault(address vault, bytes32 tournamentId)
        external
        onlyTournamentTreasury(tournamentId)
    {
        bytes32 playerId = playerIdOfVault[vault];
        if (playerId == bytes32(0)) revert Errors.NotFound();
        _removeActiveTournament(playerId, tournamentId);
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

    function _addActiveTournament(bytes32 playerId, bytes32 tournamentId) internal {
        if (tournamentId == bytes32(0)) revert Errors.ZeroId();

        bytes32[] storage active = _playerSets[playerId].tournamentData.activeTournaments;
        uint256 length = active.length;
        for (uint256 i; i < length; ++i) {
            if (active[i] == tournamentId) revert Errors.TournamentAlreadyActive(tournamentId);
        }

        active.push(tournamentId);
        emit Events.ActiveTournamentAdded(playerId, tournamentId);
    }

    function _removeActiveTournament(bytes32 playerId, bytes32 tournamentId) internal {
        bytes32[] storage active = _playerSets[playerId].tournamentData.activeTournaments;
        uint256 length = active.length;
        uint256 index = type(uint256).max;
        for (uint256 i; i < length; ++i) {
            if (active[i] == tournamentId) {
                index = i;
                break;
            }
        }
        if (index == type(uint256).max) revert Errors.TournamentNotActive(tournamentId);

        uint256 last = length - 1;
        if (index != last) active[index] = active[last];
        active.pop();
        emit Events.ActiveTournamentRemoved(playerId, tournamentId);
    }

    function _requirePlayer(bytes32 playerId) internal view returns (PlayerSet storage set) {
        set = _playerSets[playerId];
        if (set.tokenData.token == address(0)) revert Errors.NotFound();
    }
}
