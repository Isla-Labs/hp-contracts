// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

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
    bytes32 public constant UPKEEP_ROLE = keccak256("UPKEEP_ROLE");

    /// @notice Multisig + LifecycleTimelock — status / Doppler updates
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    mapping(bytes32 playerId => PlayerSet) private _playerSets;
    mapping(address token => bytes32 playerId) public playerIdOfToken;
    mapping(address vault => bytes32 playerId) public playerIdOfVault;

    bytes32[] private _playerIds;

    // --------------------------------------------
    //  Events
    // --------------------------------------------

    event PlayerRegistered(bytes32 indexed playerId, address indexed token, address indexed feeRouter);
    event StatusUpdated(bytes32 indexed playerId, PlayerStatus status);
    event LeagueIdUpdated(bytes32 indexed playerId, bytes32 indexed leagueId);
    event ActiveTournamentAdded(bytes32 indexed playerId, bytes32 indexed tournamentId);
    event ActiveTournamentRemoved(bytes32 indexed playerId, bytes32 indexed tournamentId);
    event VaultDataAdded(bytes32 indexed playerId, address playerVault, address stToken);
    event VaultDataUpdated(bytes32 indexed playerId, address playerVault, address stToken, bool isUtilized);
    event DopplerDataUpdated(bytes32 indexed playerId, address feeRouter);
    event AdvancedTradeDataAdded(bytes32 indexed playerId, address advancedTradeVault, address markSource);

    // --------------------------------------------
    //  Errors
    // --------------------------------------------

    error ZeroAddress();
    error ZeroId();
    error NotAuthorized();
    error Exists();
    error NotFound();
    error VaultDataAlreadySet(bytes32 playerId);
    error AdvancedTradeDataAlreadySet(bytes32 playerId);
    error TournamentAlreadyActive(bytes32 tournamentId);
    error TournamentNotActive(bytes32 tournamentId);

    // --------------------------------------------
    //  Access Control
    // --------------------------------------------

    modifier onlyVault() {
        _onlyVault();
        _;
    }

    function _onlyVault() internal view {
        if (playerIdOfVault[msg.sender] == bytes32(0)) revert NotAuthorized();
    }

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param admin_ Multisig: `DEFAULT_ADMIN_ROLE` + `ADMIN_ROLE` (fallback for status / Doppler).
     * @param lifecycle_ LifecycleTimelock: `LIFECYCLE_ROLE` + `ADMIN_ROLE` (primary status / Doppler path).
     * @param upkeep_ ActivityTimelock: `UPKEEP_ROLE`.
     */
    function initialize(address admin_, address lifecycle_, address upkeep_) external initializer {
        if (admin_ == address(0) || lifecycle_ == address(0) || upkeep_ == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, lifecycle_);
        _grantRole(LIFECYCLE_ROLE, lifecycle_);
        _grantRole(UPKEEP_ROLE, upkeep_);
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
        if (playerId == bytes32(0)) revert ZeroId();
        if (tokenData.token == address(0)) revert ZeroAddress();
        if (
            dopplerData.hookDoppler == address(0) || dopplerData.hookMigrator == address(0)
                || dopplerData.feeRouter == address(0)
        ) {
            revert ZeroAddress();
        }
        if (_playerSets[playerId].tokenData.token != address(0)) revert Exists();
        if (playerIdOfToken[tokenData.token] != bytes32(0)) revert Exists();

        PlayerSet storage set = _playerSets[playerId];
        set.status = PlayerStatus.BONDING;
        set.tokenData = tokenData;
        set.dopplerData = dopplerData;
        _writeTournamentData(set, tournamentData);

        playerIdOfToken[tokenData.token] = playerId;
        _playerIds.push(playerId);

        emit PlayerRegistered(playerId, tokenData.token, dopplerData.feeRouter);
        if (tournamentData.leagueId != bytes32(0)) emit LeagueIdUpdated(playerId, tournamentData.leagueId);

        uint256 n = tournamentData.activeTournaments.length;
        for (uint256 i; i < n; ++i) {
            emit ActiveTournamentAdded(playerId, tournamentData.activeTournaments[i]);
        }
    }

    /**
     * @notice Attaches vault + stToken after `PlayerVault` deployment.
     */
    function addVaultData(bytes32 playerId, VaultData calldata vaultData) external onlyRole(LIFECYCLE_ROLE) {
        PlayerSet storage set = _requirePlayer(playerId);
        if (set.vaultData.playerVault != address(0)) revert VaultDataAlreadySet(playerId);
        if (vaultData.playerVault == address(0) || vaultData.stToken == address(0)) revert ZeroAddress();
        if (playerIdOfVault[vaultData.playerVault] != bytes32(0)) revert Exists();

        set.vaultData = VaultData({
            playerVault: vaultData.playerVault, stToken: vaultData.stToken, isUtilized: vaultData.isUtilized
        });
        playerIdOfVault[vaultData.playerVault] = playerId;

        emit VaultDataAdded(playerId, vaultData.playerVault, vaultData.stToken);
    }

    /**
     * @notice Attaches Advanced Trade vault + mark source after those deployments.
     */
    function addAdvancedTradeData(bytes32 playerId, AdvancedTradeData calldata data)
        external
        onlyRole(LIFECYCLE_ROLE)
    {
        PlayerSet storage set = _requirePlayer(playerId);
        if (set.advancedTradeData.advancedTradeVault != address(0)) revert AdvancedTradeDataAlreadySet(playerId);
        if (data.advancedTradeVault == address(0) || data.markSource == address(0)) revert ZeroAddress();

        set.advancedTradeData = data;
        emit AdvancedTradeDataAdded(playerId, data.advancedTradeVault, data.markSource);
    }

    // --------------------------------------------
    //  Upkeep
    // --------------------------------------------

    function updateUtilization(bool isUtilized) external onlyVault {
        bytes32 playerId = playerIdOfVault[msg.sender];
        PlayerSet storage set = _playerSets[playerId];
        if (set.vaultData.playerVault != msg.sender) revert NotAuthorized();

        set.vaultData.isUtilized = isUtilized;
        emit VaultDataUpdated(playerId, set.vaultData.playerVault, set.vaultData.stToken, isUtilized);
    }

    function setStatus(bytes32 playerId, PlayerStatus status) external onlyRole(ADMIN_ROLE) {
        _requirePlayer(playerId);
        _playerSets[playerId].status = status;
        emit StatusUpdated(playerId, status);
    }

    function setLeagueId(bytes32 playerId, bytes32 leagueId) external onlyRole(LIFECYCLE_ROLE) {
        _requirePlayer(playerId);
        _playerSets[playerId].tournamentData.leagueId = leagueId;
        emit LeagueIdUpdated(playerId, leagueId);
    }

    function addActiveTournament(bytes32 playerId, bytes32 tournamentId) external onlyRole(UPKEEP_ROLE) {
        _requirePlayer(playerId);
        _addActiveTournament(playerId, tournamentId);
    }

    function removeActiveTournament(bytes32 playerId, bytes32 tournamentId) external onlyRole(UPKEEP_ROLE) {
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
        if (index == type(uint256).max) revert TournamentNotActive(tournamentId);

        uint256 last = length - 1;
        if (index != last) active[index] = active[last];
        active.pop();
        emit ActiveTournamentRemoved(playerId, tournamentId);
    }

    /// @notice Updates Doppler fields after migration / hook replacement
    function setDopplerData(bytes32 playerId, DopplerData calldata data) external onlyRole(ADMIN_ROLE) {
        _requirePlayer(playerId);
        if (data.hookDoppler == address(0) || data.hookMigrator == address(0) || data.feeRouter == address(0)) {
            revert ZeroAddress();
        }
        _playerSets[playerId].dopplerData = data;
        emit DopplerDataUpdated(playerId, data.feeRouter);
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
            if (tournamentId == bytes32(0)) revert ZeroId();
            for (uint256 j; j < i; ++j) {
                if (tournamentData.activeTournaments[j] == tournamentId) {
                    revert TournamentAlreadyActive(tournamentId);
                }
            }
            set.tournamentData.activeTournaments.push(tournamentId);
        }
    }

    function _addActiveTournament(bytes32 playerId, bytes32 tournamentId) internal {
        if (tournamentId == bytes32(0)) revert ZeroId();

        bytes32[] storage active = _playerSets[playerId].tournamentData.activeTournaments;
        uint256 length = active.length;
        for (uint256 i; i < length; ++i) {
            if (active[i] == tournamentId) revert TournamentAlreadyActive(tournamentId);
        }

        active.push(tournamentId);
        emit ActiveTournamentAdded(playerId, tournamentId);
    }

    function _requirePlayer(bytes32 playerId) internal view returns (PlayerSet storage set) {
        set = _playerSets[playerId];
        if (set.tokenData.token == address(0)) revert NotFound();
    }
}
