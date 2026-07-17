// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

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

/**
 * @title PlayerSetRegistry
 * @notice Canonical per-player market discovery set (`playerId` → `PlayerSet`).
 * @dev Access:
 *      - `LIFECYCLE_ROLE` (LifecycleTimelock): register player + Doppler/tournament data;
 *        add vault / advanced-trade sets; league transfers.
 *      - `UPKEEP_ROLE` (ActivityTimelock): add / remove active tournaments.
 *      - `ADMIN_ROLE` (multisig + LifecycleTimelock): status and Doppler updates
 *        (LifecycleTimelock is the primary path; multisig is the public-migrate fallback).
 *      - Registered vaults: `updateUtilization` via `onlyVault`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerSetRegistry is Initializable, AccessControl {
    /// @notice LifecycleTimelock — market deployment / player-set registration
    bytes32 public constant LIFECYCLE_ROLE = keccak256("LIFECYCLE_ROLE");

    /// @notice ActivityTimelock — per-player active tournament upkeep
    bytes32 public constant ACTIVITY_ROLE = keccak256("ACTIVITY_ROLE");

    /// @notice Multisig + LifecycleTimelock — status / Doppler updates
    bytes32 public constant UPDATE_ROLE = keccak256("UPDATE_ROLE");

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
        _onlyVault();
        _;
    }

    function _onlyVault() internal view {
        if (playerIdOfVault[msg.sender] == bytes32(0)) revert Errors.NotAuthorized();
    }

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param updateAuthority_ Multisig: `DEFAULT_ADMIN_ROLE` + `ADMIN_ROLE` (fallback for status / Doppler).
     * @param lifecycleTimelock_ LifecycleTimelock: `LIFECYCLE_ROLE` + `ADMIN_ROLE` (primary status / Doppler path).
     * @param activityTimelock_ ActivityTimelock: `UPKEEP_ROLE`.
     */
    function initialize(address admin_, address updateAuthority_, address lifecycleTimelock_, address activityTimelock_) external initializer {
        if (admin_ == address(0) || updateAuthority_ == address(0) || lifecycleTimelock_ == address(0) || activityTimelock_ == address(0)) revert Errors.ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_); // replace with governance
        _grantRole(UPDATE_ROLE, updateAuthority_); // replace with governance
        _grantRole(UPDATE_ROLE, lifecycleTimelock_); // replace with governance
        _grantRole(LIFECYCLE_ROLE, lifecycleTimelock_); // replace with governance
        _grantRole(ACTIVITY_ROLE, activityTimelock_); // replace with governance
    }

    // --------------------------------------------
    //  Registration
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
    ) external onlyRole(LIFECYCLE_ROLE) {
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
    function addVaultData(bytes32 playerId, VaultData calldata vaultData) external onlyRole(LIFECYCLE_ROLE) {
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
        onlyRole(LIFECYCLE_ROLE)
    {
        PlayerSet storage set = _requirePlayer(playerId);
        if (set.advancedTradeData.advancedTradeVault != address(0)) revert Errors.AdvancedTradeDataAlreadySet(playerId);
        if (data.advancedTradeVault == address(0) || data.markSource == address(0)) revert Errors.ZeroAddress();

        set.advancedTradeData = data;
        emit Events.AdvancedTradeDataAdded(playerId, data.advancedTradeVault, data.markSource);
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

    function setStatus(bytes32 playerId, PlayerStatus status) external onlyRole(UPDATE_ROLE) {
        _requirePlayer(playerId);
        _playerSets[playerId].status = status;
        emit Events.StatusUpdated(playerId, status);
    }

    function setLeagueId(bytes32 playerId, bytes32 leagueId) external onlyRole(LIFECYCLE_ROLE) {
        _requirePlayer(playerId);
        _playerSets[playerId].tournamentData.leagueId = leagueId;
        emit Events.LeagueIdUpdated(playerId, leagueId);
    }

    function addActiveTournament(bytes32 playerId, bytes32 tournamentId) external onlyRole(ACTIVITY_ROLE) {
        _requirePlayer(playerId);
        _addActiveTournament(playerId, tournamentId);
    }

    function removeActiveTournament(bytes32 playerId, bytes32 tournamentId) external onlyRole(ACTIVITY_ROLE) {
        _requirePlayer(playerId);

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

    /// @notice Updates Doppler fields after migration / hook replacement
    function setDopplerData(bytes32 playerId, DopplerData calldata data) external onlyRole(UPDATE_ROLE) {
        _requirePlayer(playerId);
        if (data.hookDoppler == address(0) || data.hookMigrator == address(0) || data.feeRouter == address(0)) {
            revert Errors.ZeroAddress();
        }
        _playerSets[playerId].dopplerData = data;
        emit Events.DopplerDataUpdated(playerId, data.feeRouter);
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

    function _requirePlayer(bytes32 playerId) internal view returns (PlayerSet storage set) {
        set = _playerSets[playerId];
        if (set.tokenData.token == address(0)) revert Errors.NotFound();
    }
}
