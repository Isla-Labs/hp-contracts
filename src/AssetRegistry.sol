// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/access/Ownable2Step.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import {
    ActiveTournament,
    AdvancedTradeData,
    AssetData,
    MarketStatus,
    PlayerVaultData,
    SpotMarketData
} from "@base/global/types/AssetTypes.sol";

/**
 * @title AssetRegistry
 * @notice Canonizes per-market discovery data keyed by `playerId`.
 * @dev Owner should be LifecycleTimelock. Identity (`AssetData`) and each subsystem set
 *      (`SpotMarketData`, `AdvancedTradeData`, `PlayerVaultData`, `ActiveTournament`) live in
 *      independent mappings so deployments can land in any order after `createAsset`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract AssetRegistry is Ownable2Step {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    mapping(bytes32 playerId => AssetData) private _assets;
    mapping(bytes32 playerId => SpotMarketData) private _spotMarketData;
    mapping(bytes32 playerId => AdvancedTradeData) private _advancedTradeData;
    mapping(bytes32 playerId => PlayerVaultData) private _playerVaultData;
    mapping(bytes32 playerId => ActiveTournament) private _activeTournaments;

    mapping(address token => bytes32 playerId) public playerIdOfToken;

    bytes32[] private _playerIds;

    // --------------------------------------------
    //  Events
    // --------------------------------------------

    event AssetCreated(bytes32 indexed playerId, address indexed token, bytes32 indexed leagueId, string symbol);
    event MarketStatusUpdated(bytes32 indexed playerId, MarketStatus status);
    event SpotMarketDataUpdated(bytes32 indexed playerId, address feeRouter);
    event AdvancedTradeDataUpdated(bytes32 indexed playerId, address advancedTradeVault, address markSource);
    event PlayerVaultDataUpdated(bytes32 indexed playerId, address playerVault, address stToken, bool isUtilized);
    event LeagueIdUpdated(bytes32 indexed playerId, bytes32 indexed leagueId);
    event CupIdAdded(bytes32 indexed playerId, bytes32 indexed cupId, uint256 cupIndex);
    event CupIdRemoved(bytes32 indexed playerId, bytes32 indexed cupId);

    // --------------------------------------------
    //  Errors
    // --------------------------------------------

    error ZeroAddress();
    error ZeroId();
    error AssetAlreadyExists(bytes32 playerId);
    error UnknownAsset(bytes32 playerId);
    error TokenTaken(address token, bytes32 existingPlayerId);
    error CupIdAlreadyActive(bytes32 playerId, bytes32 cupId);
    error CupIdNotActive(bytes32 playerId, bytes32 cupId);

    // --------------------------------------------
    //  Init
    // --------------------------------------------

    /**
     * @param initialOwner Contract owner. Should be `LifecycleTimelock` at deployment.
     */
    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    // --------------------------------------------
    //  Writes — identity
    // --------------------------------------------

    /**
     * @notice Registers a new player market identity. Subsystem sets can be filled later.
     * @param playerId Primary key for this market.
     * @param leagueId Domestic league binding (must exist in TournamentRegistry offchain/onchain).
     * @param token Deployed player token address.
     * @param symbol Token symbol for discovery UIs.
     */
    function createAsset(bytes32 playerId, bytes32 leagueId, address token, string calldata symbol)
        external
        onlyOwner
    {
        if (playerId == bytes32(0) || leagueId == bytes32(0)) revert ZeroId();
        if (token == address(0)) revert ZeroAddress();
        if (_assets[playerId].token != address(0)) revert AssetAlreadyExists(playerId);

        bytes32 existingPlayerId = playerIdOfToken[token];
        if (existingPlayerId != bytes32(0)) revert TokenTaken(token, existingPlayerId);

        _assets[playerId] = AssetData({
            leagueId: leagueId,
            token: token,
            symbol: symbol,
            marketStatus: MarketStatus.BONDING,
            deployedAt: block.timestamp,
            graduatedAt: 0,
            deactivatedAt: 0
        });
        _activeTournaments[playerId].leagueId = leagueId;
        playerIdOfToken[token] = playerId;
        _playerIds.push(playerId);

        emit AssetCreated(playerId, token, leagueId, symbol);
    }

    function setMarketStatus(bytes32 playerId, MarketStatus status) external onlyOwner {
        AssetData storage asset = _requireAsset(playerId);
        asset.marketStatus = status;
        if (status == MarketStatus.GRADUATED && asset.graduatedAt == 0) {
            asset.graduatedAt = block.timestamp;
        }
        if (status == MarketStatus.DEACTIVATED) {
            asset.deactivatedAt = block.timestamp;
        }
        emit MarketStatusUpdated(playerId, status);
    }

    /// @notice Updates league binding on identity and active tournament (e.g. domestic transfer).
    function setLeagueId(bytes32 playerId, bytes32 leagueId) external onlyOwner {
        if (leagueId == bytes32(0)) revert ZeroId();
        _requireAsset(playerId).leagueId = leagueId;
        _activeTournaments[playerId].leagueId = leagueId;
        emit LeagueIdUpdated(playerId, leagueId);
    }

    // --------------------------------------------
    //  Writes — active tournament cups
    // --------------------------------------------

    /**
     * @notice Appends a cup to the player's active tournament set.
     * @dev Cup membership is independent of TournamentRegistry calendar writes; LifecycleTimelock
     *      is expected to keep both in sync.
     */
    function addCupId(bytes32 playerId, bytes32 cupId) external onlyOwner {
        if (cupId == bytes32(0)) revert ZeroId();
        _requireAsset(playerId);

        ActiveTournament storage active = _activeTournaments[playerId];
        if (_findCupIndex(active, cupId) != type(uint256).max) revert CupIdAlreadyActive(playerId, cupId);

        active.cupIds.push(cupId);
        emit CupIdAdded(playerId, cupId, active.cupIds.length - 1);
    }

    /**
     * @notice Removes a cup from the player's active tournament set (swap-and-pop).
     */
    function removeCupId(bytes32 playerId, bytes32 cupId) external onlyOwner {
        if (cupId == bytes32(0)) revert ZeroId();
        _requireAsset(playerId);

        ActiveTournament storage active = _activeTournaments[playerId];
        uint256 index = _findCupIndex(active, cupId);
        if (index == type(uint256).max) revert CupIdNotActive(playerId, cupId);

        uint256 lastIndex = active.cupIds.length - 1;
        if (index != lastIndex) {
            active.cupIds[index] = active.cupIds[lastIndex];
        }
        active.cupIds.pop();

        emit CupIdRemoved(playerId, cupId);
    }

    // --------------------------------------------
    //  Writes — independently deployable sets
    // --------------------------------------------

    function setSpotMarketData(bytes32 playerId, SpotMarketData calldata spot) external onlyOwner {
        _requireAsset(playerId);
        _spotMarketData[playerId] = spot;
        emit SpotMarketDataUpdated(playerId, spot.feeRouter);
    }

    function setActivePool(bytes32 playerId, PoolKey calldata activePool) external onlyOwner {
        _requireAsset(playerId);
        _spotMarketData[playerId].activePool = activePool;
        emit SpotMarketDataUpdated(playerId, _spotMarketData[playerId].feeRouter);
    }

    function setAdvancedTradeData(bytes32 playerId, AdvancedTradeData calldata data) external onlyOwner {
        _requireAsset(playerId);
        _advancedTradeData[playerId] = data;
        emit AdvancedTradeDataUpdated(playerId, data.advancedTradeVault, data.markSource);
    }

    function setPlayerVaultData(bytes32 playerId, PlayerVaultData calldata data) external onlyOwner {
        _requireAsset(playerId);
        _playerVaultData[playerId] = data;
        emit PlayerVaultDataUpdated(playerId, data.playerVault, data.stToken, data.isUtilized);
    }

    function setUtilized(bytes32 playerId, bool isUtilized) external onlyOwner {
        PlayerVaultData storage vaultData = _playerVaultData[playerId];
        _requireAsset(playerId);
        vaultData.isUtilized = isUtilized;
        emit PlayerVaultDataUpdated(playerId, vaultData.playerVault, vaultData.stToken, isUtilized);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function getAssetData(bytes32 playerId) external view returns (AssetData memory) {
        return _requireAsset(playerId);
    }

    function getSpotMarketData(bytes32 playerId) external view returns (SpotMarketData memory) {
        _requireAsset(playerId);
        return _spotMarketData[playerId];
    }

    function getAdvancedTradeData(bytes32 playerId) external view returns (AdvancedTradeData memory) {
        _requireAsset(playerId);
        return _advancedTradeData[playerId];
    }

    function getPlayerVaultData(bytes32 playerId) external view returns (PlayerVaultData memory) {
        _requireAsset(playerId);
        return _playerVaultData[playerId];
    }

    function getActiveTournament(bytes32 playerId) external view returns (ActiveTournament memory) {
        _requireAsset(playerId);
        return _activeTournaments[playerId];
    }

    function exists(bytes32 playerId) external view returns (bool) {
        return _assets[playerId].token != address(0);
    }

    function playerIdCount() external view returns (uint256) {
        return _playerIds.length;
    }

    function playerIdAt(uint256 index) external view returns (bytes32) {
        return _playerIds[index];
    }

    function playerIds() external view returns (bytes32[] memory) {
        return _playerIds;
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _requireAsset(bytes32 playerId) internal view returns (AssetData storage asset) {
        asset = _assets[playerId];
        if (asset.token == address(0)) revert UnknownAsset(playerId);
    }

    function _findCupIndex(ActiveTournament storage active, bytes32 cupId) internal view returns (uint256) {
        uint256 length = active.cupIds.length;
        for (uint256 i; i < length; ++i) {
            if (active.cupIds[i] == cupId) return i;
        }
        return type(uint256).max;
    }
}
