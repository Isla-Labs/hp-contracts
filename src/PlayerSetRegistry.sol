// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import {
    AdvancedTradeData,
    DopplerData,
    PlayerSet,
    PlayerStatus,
    TokenData,
    TournamentData,
    VaultData
} from "@base/global/types/latest/PlayerSetTypes.sol";

/**
 * @title PlayerSetRegistry
 * @notice Canonical per-player market discovery set (`playerId` → `PlayerSet`).
 * @dev Simple registration pattern (cf. legacy `VaultRegistry`): factory writes the set,
 *      vaults may update utilization, views are permissionless.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerSetRegistry is Initializable {
    address public playerVaultFactory;
    address public admin;

    mapping(bytes32 playerId => PlayerSet) private _playerSets;
    mapping(address token => bytes32 playerId) public playerIdOfToken;
    mapping(address vault => bytes32 playerId) public playerIdOfVault;

    bytes32[] private _playerIds;

    event FactorySet(address indexed factory);
    event AdminSet(address indexed admin);
    event PlayerRegistered(bytes32 indexed playerId, address indexed token, address indexed vault);
    event StatusUpdated(bytes32 indexed playerId, PlayerStatus status);
    event LeagueIdUpdated(bytes32 indexed playerId, bytes32 indexed leagueId);
    event ActiveTournamentAdded(bytes32 indexed playerId, bytes32 indexed tournamentId);
    event ActiveTournamentRemoved(bytes32 indexed playerId, bytes32 indexed tournamentId);
    event VaultDataUpdated(bytes32 indexed playerId, address playerVault, address stToken, bool isUtilized);
    event DopplerDataUpdated(bytes32 indexed playerId, address feeRouter);
    event AdvancedTradeDataUpdated(bytes32 indexed playerId, address advancedTradeVault, address markSource);

    error ZeroAddress();
    error ZeroId();
    error NotAuthorized();
    error Exists();
    error NotFound();
    error TournamentAlreadyActive(bytes32 tournamentId);
    error TournamentNotActive(bytes32 tournamentId);

    modifier onlyFactory() {
        if (msg.sender != playerVaultFactory) revert NotAuthorized();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAuthorized();
        _;
    }

    modifier onlyVault() {
        if (playerIdOfVault[msg.sender] == bytes32(0)) revert NotAuthorized();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_, address playerVaultFactory_) external initializer {
        if (admin_ == address(0) || playerVaultFactory_ == address(0)) revert ZeroAddress();
        admin = admin_;
        playerVaultFactory = playerVaultFactory_;
        emit AdminSet(admin_);
        emit FactorySet(playerVaultFactory_);
    }

    // --------------------------------------------
    //  Registration
    // --------------------------------------------

    /**
     * @notice Registers a new player market set. Called by `PlayerVaultFactory`.
     * @dev Subsystem addresses may be zero at first registration and filled in later by admin.
     */
    function addPlayerSet(
        bytes32 playerId,
        TokenData calldata tokenData,
        bytes32 leagueId,
        VaultData calldata vaultData
    ) external onlyFactory {
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

    function setStatus(bytes32 playerId, PlayerStatus status) external onlyAdmin {
        _requirePlayer(playerId);
        _playerSets[playerId].status = status;
        emit StatusUpdated(playerId, status);
    }

    function setLeagueId(bytes32 playerId, bytes32 leagueId) external onlyAdmin {
        _requirePlayer(playerId);
        _playerSets[playerId].tournamentData.leagueId = leagueId;
        emit LeagueIdUpdated(playerId, leagueId);
    }

    function addActiveTournament(bytes32 playerId, bytes32 tournamentId) external onlyAdmin {
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

    function removeActiveTournament(bytes32 playerId, bytes32 tournamentId) external onlyAdmin {
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

    function setDopplerData(bytes32 playerId, DopplerData calldata data) external onlyAdmin {
        _requirePlayer(playerId);
        _playerSets[playerId].dopplerData = data;
        emit DopplerDataUpdated(playerId, data.feeRouter);
    }

    function setAdvancedTradeData(bytes32 playerId, AdvancedTradeData calldata data) external onlyAdmin {
        _requirePlayer(playerId);
        _playerSets[playerId].advancedTradeData = data;
        emit AdvancedTradeDataUpdated(playerId, data.advancedTradeVault, data.markSource);
    }

    function setPlayerVaultFactory(address factory) external onlyAdmin {
        if (factory == address(0)) revert ZeroAddress();
        playerVaultFactory = factory;
        emit FactorySet(factory);
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
