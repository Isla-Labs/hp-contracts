// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { RegistryErrors as Errors } from "@errors/RegistryErrors.sol";
import { RegistryEvents as Events } from "@events/RegistryEvents.sol";
import {
    AdvancedTradeData,
    DopplerData,
    PlayerSet,
    PlayerStatus,
    TokenData,
    TournamentData,
    VaultData
} from "@types/PlayerSetTypes.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";

/// @dev Minimal FeeRouter surface for status cache sync (avoids markets import).
interface IFeeRouterStatus {
    function setStatus(PlayerStatus status_) external;
}

/**
 * @title PlayerSetRegistry
 * @notice Canonical per-player market discovery set (`playerId` → `PlayerSet`).
 * @dev Access:
 *      - Owner (`Orchestrator`): registration, status, league / optional `activeTournaments`
 *        index, and Doppler updates.
 *      - Vault membership SoT is `TournamentRegistry` (not mirrored here).
 *      - Registered vaults: `updateUtilization` via `onlyVault`.
 *      - `setStatus` always syncs `FeeRouter.status` (integrator share cache).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerSetRegistry is Initializable, AddressBook, Ownable, IPlayerSetRegistry {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    ITournamentRegistry public tournamentRegistry;

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

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    /// @notice Transfers ownership to `Orchestrator` and resolves `TournamentRegistry` from `AddressProvider` once.
    function initialize() external initializer {
        _transferOwnership(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));
        tournamentRegistry = ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }

    // --------------------------------------------
    //  Registration (owner)
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
    ) external onlyOwner {
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
    function addVaultData(bytes32 playerId, VaultData calldata vaultData) external onlyOwner {
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
    function addAdvancedTradeData(bytes32 playerId, AdvancedTradeData calldata data) external onlyOwner {
        PlayerSet storage set = _requirePlayer(playerId);
        if (set.advancedTradeData.advancedTradeVault != address(0)) {
            revert Errors.AdvancedTradeDataAlreadySet(playerId);
        }
        if (data.advancedTradeVault == address(0) || data.markSource == address(0)) revert Errors.ZeroAddress();

        set.advancedTradeData = data;
        emit Events.AdvancedTradeDataAdded(playerId, data.advancedTradeVault, data.markSource);
    }

    /// @notice Updates Doppler fields after migration / hook replacement
    function setDopplerData(bytes32 playerId, DopplerData calldata data) external onlyOwner {
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

    /**
     * @notice Updates lifecycle status and syncs the per-market `FeeRouter.status` cache.
     * @dev Migration / eligibility listeners → Orchestrator → here.
     */
    function setStatus(bytes32 playerId, PlayerStatus status) external onlyOwner {
        PlayerSet storage set = _requirePlayer(playerId);
        set.status = status;
        emit Events.StatusUpdated(playerId, status);

        IFeeRouterStatus(set.dopplerData.feeRouter).setStatus(status);
    }

    function setLeagueId(bytes32 playerId, bytes32 leagueId) external onlyOwner {
        _requirePlayer(playerId);
        _playerSets[playerId].tournamentData.leagueId = leagueId;
        emit Events.LeagueIdUpdated(playerId, leagueId);
    }

    function addActiveTournament(bytes32 playerId, bytes32 tournamentId) external onlyOwner {
        _requirePlayer(playerId);
        _addActiveTournament(playerId, tournamentId);
    }

    function removeActiveTournament(bytes32 playerId, bytes32 tournamentId) external onlyOwner {
        _requirePlayer(playerId);
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
