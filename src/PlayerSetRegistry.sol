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
 *      - `DEPLOYER_ROLE` (LifecycleTimelock): register new player sets.
 *      - `ADMIN_ROLE` (multisig initially): status / league / tournament / subsystem updates.
 *      - Registered vaults: `updateUtilization` via `onlyVault`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerSetRegistry is Initializable, AccessControl {
    /// @notice LifecycleTimelock — market deployment / player-set registration
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    /// @notice Admin (multisig) — registry upkeep
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

    event PlayerRegistered(bytes32 indexed playerId, address indexed token, address indexed vault);
    event StatusUpdated(bytes32 indexed playerId, PlayerStatus status);
    event LeagueIdUpdated(bytes32 indexed playerId, bytes32 indexed leagueId);
    event ActiveTournamentAdded(bytes32 indexed playerId, bytes32 indexed tournamentId);
    event ActiveTournamentRemoved(bytes32 indexed playerId, bytes32 indexed tournamentId);
    event VaultDataUpdated(bytes32 indexed playerId, address playerVault, address stToken, bool isUtilized);
    event DopplerDataUpdated(bytes32 indexed playerId, address feeRouter);
    event AdvancedTradeDataUpdated(bytes32 indexed playerId, address advancedTradeVault, address markSource);

    // --------------------------------------------
    //  Errors
    // --------------------------------------------

    error ZeroAddress();
    error ZeroId();
    error NotAuthorized();
    error Exists();
    error NotFound();
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
     * @param admin_ Multisig granted `ADMIN_ROLE` (+ `DEFAULT_ADMIN_ROLE` for role management).
     * @param deployer_ LifecycleTimelock granted `DEPLOYER_ROLE`.
     */
    function initialize(address admin_, address deployer_) external initializer {
        if (admin_ == address(0) || deployer_ == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(DEPLOYER_ROLE, deployer_);
    }

    // --------------------------------------------
    //  Registration
    // --------------------------------------------

    /**
     * @notice Registers a new player market set.
     * @dev LifecycleTimelock (`DEPLOYER_ROLE`). Subsystem addresses may be filled in later by admin.
     */
    function addPlayerSet(
        bytes32 playerId,
        TokenData calldata tokenData,
        bytes32 leagueId,
        VaultData calldata vaultData
    ) external onlyRole(DEPLOYER_ROLE) {
        if (playerId == bytes32(0)) revert ZeroId();
        if (tokenData.token == address(0) || vaultData.playerVault == address(0) || vaultData.stToken == address(0)) {
            revert ZeroAddress();
        }
        if (_playerSets[playerId].tokenData.token != address(0)) revert Exists();
        if (playerIdOfToken[tokenData.token] != bytes32(0)) revert Exists();
        if (playerIdOfVault[vaultData.playerVault] != bytes32(0)) revert Exists();

        PlayerSet storage set = _playerSets[playerId];
        set.status = PlayerStatus.BONDING;
        set.tokenData = tokenData;
        set.tournamentData.leagueId = leagueId;
        set.vaultData = vaultData;

        playerIdOfToken[tokenData.token] = playerId;
        playerIdOfVault[vaultData.playerVault] = playerId;
        _playerIds.push(playerId);

        emit PlayerRegistered(playerId, tokenData.token, vaultData.playerVault);
        if (leagueId != bytes32(0)) emit LeagueIdUpdated(playerId, leagueId);
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

    function setLeagueId(bytes32 playerId, bytes32 leagueId) external onlyRole(ADMIN_ROLE) {
        _requirePlayer(playerId);
        _playerSets[playerId].tournamentData.leagueId = leagueId;
        emit LeagueIdUpdated(playerId, leagueId);
    }

    function addActiveTournament(bytes32 playerId, bytes32 tournamentId) external onlyRole(ADMIN_ROLE) {
        _requirePlayer(playerId);
        if (tournamentId == bytes32(0)) revert ZeroId();

        bytes32[] storage active = _playerSets[playerId].tournamentData.activeTournaments;
        uint256 length = active.length;
        for (uint256 i; i < length; ++i) {
            if (active[i] == tournamentId) revert TournamentAlreadyActive(tournamentId);
        }

        active.push(tournamentId);
        emit ActiveTournamentAdded(playerId, tournamentId);
    }

    function removeActiveTournament(bytes32 playerId, bytes32 tournamentId) external onlyRole(ADMIN_ROLE) {
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

    function setDopplerData(bytes32 playerId, DopplerData calldata data) external onlyRole(ADMIN_ROLE) {
        _requirePlayer(playerId);
        _playerSets[playerId].dopplerData = data;
        emit DopplerDataUpdated(playerId, data.feeRouter);
    }

    function setAdvancedTradeData(bytes32 playerId, AdvancedTradeData calldata data) external onlyRole(ADMIN_ROLE) {
        _requirePlayer(playerId);
        _playerSets[playerId].advancedTradeData = data;
        emit AdvancedTradeDataUpdated(playerId, data.advancedTradeVault, data.markSource);
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

    function getVaultData(bytes32 playerId) external view returns (VaultData memory) {
        _requirePlayer(playerId);
        return _playerSets[playerId].vaultData;
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

    function _requirePlayer(bytes32 playerId) internal view {
        if (_playerSets[playerId].tokenData.token == address(0)) revert NotFound();
    }
}
