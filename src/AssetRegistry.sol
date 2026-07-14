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
 * @notice Canonizes per-market `AssetData` for discovery (pools, AT vault, PlayerVault, status).
 * @dev Owner should be LifecycleTimelock. `createAsset` is invoked from `executeDeployment`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract AssetRegistry is Ownable2Step {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    mapping(address token => AssetData data) private _assets;
    mapping(bytes32 playerId => address token) public tokenOfPlayerId;

    address[] private _tokens;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    event AssetCreated(address indexed token, bytes32 indexed playerId, bytes32 indexed leagueId, string symbol);
    event MarketStatusUpdated(address indexed token, MarketStatus status);
    event SpotMarketDataUpdated(address indexed token, address feeRouter);
    event AdvancedTradeDataUpdated(address indexed token, address advancedTradeVault, address markSource);
    event PlayerVaultDataUpdated(address indexed token, address playerVault, address stToken, bool isUtilized);
    event LeagueIdUpdated(address indexed token, bytes32 indexed leagueId);

    error ZeroAddress();
    error ZeroId();
    error AssetAlreadyExists();
    error UnknownAsset();
    error PlayerIdTaken(bytes32 playerId, address existingToken);
    error TokenMismatch();

    // --------------------------------------------
    //  Init
    // --------------------------------------------

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    // --------------------------------------------
    //  Writes
    // --------------------------------------------

    /**
     * @notice Registers a new market. `token` must equal `_assetData.token`.
     */
    function createAsset(address token, AssetData memory _assetData) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (_assetData.playerId == bytes32(0) || _assetData.leagueId == bytes32(0)) revert ZeroId();
        if (_assetData.token != token) revert TokenMismatch();
        if (_assets[token].token != address(0)) revert AssetAlreadyExists();

        address existing = tokenOfPlayerId[_assetData.playerId];
        if (existing != address(0)) revert PlayerIdTaken(_assetData.playerId, existing);

        if (_assetData.registryData.deployedAt == 0) {
            _assetData.registryData.deployedAt = block.timestamp;
        }

        _assets[token] = _assetData;
        tokenOfPlayerId[_assetData.playerId] = token;
        _tokens.push(token);

        emit AssetCreated(token, _assetData.playerId, _assetData.leagueId, _assetData.symbol);
    }

    function setMarketStatus(address token, MarketStatus status) external onlyOwner {
        AssetData storage asset = _requireAsset(token);
        asset.marketStatus = status;
        if (status == MarketStatus.GRADUATED && asset.registryData.graduatedAt == 0) {
            asset.registryData.graduatedAt = block.timestamp;
        }
        if (status == MarketStatus.DEACTIVATED) {
            asset.registryData.deactivatedAt = block.timestamp;
        }
        emit MarketStatusUpdated(token, status);
    }

    function setSpotMarketData(address token, SpotMarketData calldata spot) external onlyOwner {
        AssetData storage asset = _requireAsset(token);
        asset.registryData.spotMarketData = spot;
        emit SpotMarketDataUpdated(token, spot.feeRouter);
    }

    function setActivePool(address token, PoolKey calldata activePool) external onlyOwner {
        AssetData storage asset = _requireAsset(token);
        asset.registryData.spotMarketData.activePool = activePool;
        emit SpotMarketDataUpdated(token, asset.registryData.spotMarketData.feeRouter);
    }

    function setAdvancedTradeData(address token, AdvancedTradeData calldata data) external onlyOwner {
        AssetData storage asset = _requireAsset(token);
        asset.registryData.advancedTradeData = data;
        emit AdvancedTradeDataUpdated(token, data.advancedTradeVault, data.markSource);
    }

    function setPlayerVaultData(address token, PlayerVaultData calldata data) external onlyOwner {
        AssetData storage asset = _requireAsset(token);
        asset.registryData.playerVaultData = data;
        emit PlayerVaultDataUpdated(token, data.playerVault, data.stToken, data.isUtilized);
    }

    function setUtilized(address token, bool isUtilized) external onlyOwner {
        AssetData storage asset = _requireAsset(token);
        asset.registryData.playerVaultData.isUtilized = isUtilized;
        emit PlayerVaultDataUpdated(
            token,
            asset.registryData.playerVaultData.playerVault,
            asset.registryData.playerVaultData.stToken,
            isUtilized
        );
    }

    /// @notice Updates league binding (e.g. transfer / new league treasury routing).
    function setLeagueId(address token, bytes32 leagueId) external onlyOwner {
        if (leagueId == bytes32(0)) revert ZeroId();
        AssetData storage asset = _requireAsset(token);
        asset.leagueId = leagueId;
        emit LeagueIdUpdated(token, leagueId);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function getAssetData(address token) external view returns (AssetData memory) {
        return _assets[token];
    }

    function exists(address token) external view returns (bool) {
        return _assets[token].token != address(0);
    }

    function tokenCount() external view returns (uint256) {
        return _tokens.length;
    }

    function tokenAt(uint256 index) external view returns (address) {
        return _tokens[index];
    }

    function tokens() external view returns (address[] memory) {
        return _tokens;
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _requireAsset(address token) internal view returns (AssetData storage asset) {
        asset = _assets[token];
        if (asset.token == address(0)) revert UnknownAsset();
    }
}
