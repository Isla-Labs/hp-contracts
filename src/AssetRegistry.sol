// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/access/Ownable2Step.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import {
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
 *      (`SpotMarketData`, `AdvancedTradeData`, `PlayerVaultData`) live in independent mappings
 *      so deployments can land in any order after `createAsset`.
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

    // --------------------------------------------
    //  Errors
    // --------------------------------------------

    error ZeroAddress();
    error ZeroId();
    error AssetAlreadyExists(bytes32 playerId);
    error UnknownAsset(bytes32 playerId);
    error TokenTaken(address token, bytes32 existingPlayerId);

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

    /// @notice Updates league binding (e.g. transfer / new league treasury routing).
    function setLeagueId(bytes32 playerId, bytes32 leagueId) external onlyOwner {
        if (leagueId == bytes32(0)) revert ZeroId();
        _requireAsset(playerId).leagueId = leagueId;
        emit LeagueIdUpdated(playerId, leagueId);
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
}
