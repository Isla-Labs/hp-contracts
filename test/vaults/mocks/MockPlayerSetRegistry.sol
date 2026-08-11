// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { DopplerData, TournamentData, VaultData } from "@types/registries/PlayerSetTypes.sol";

/// @notice Records utilization flips from PlayerVault stake/unstake; minimal PSR reads for routers.
contract MockPlayerSetRegistry {
    bool public lastUtilized;
    uint256 public updateCount;
    address public lastCaller;

    mapping(bytes32 playerId => bytes32[]) internal _activeTournaments;
    mapping(address token => bytes32 playerId) public playerIdOfToken;
    mapping(bytes32 playerId => VaultData) internal _vaultData;
    mapping(bytes32 playerId => DopplerData) internal _dopplerData;

    function setActiveTournaments(bytes32 playerId, bytes32[] calldata tournamentIds) external {
        delete _activeTournaments[playerId];
        for (uint256 i; i < tournamentIds.length; ++i) {
            _activeTournaments[playerId].push(tournamentIds[i]);
        }
    }

    function setPlayerToken(bytes32 playerId, address token) external {
        playerIdOfToken[token] = playerId;
    }

    function setVaultData(bytes32 playerId, address vault, address stToken) external {
        _vaultData[playerId] = VaultData({ playerVault: vault, stToken: stToken, isUtilized: false });
    }

    function setDopplerData(bytes32 playerId, DopplerData calldata data) external {
        _dopplerData[playerId] = data;
    }

    function graduatePool(bytes32 playerId, PoolKey calldata activePool) external {
        _dopplerData[playerId].activePool = activePool;
    }

    function updateUtilization(bool isUtilized) external {
        lastUtilized = isUtilized;
        lastCaller = msg.sender;
        unchecked {
            ++updateCount;
        }
    }

    function getTournamentData(bytes32 playerId) external view returns (TournamentData memory data) {
        data.leagueId = bytes32(0);
        data.activeTournaments = _activeTournaments[playerId];
    }

    function getVaultData(bytes32 playerId) external view returns (VaultData memory) {
        return _vaultData[playerId];
    }

    function getDopplerData(bytes32 playerId) external view returns (DopplerData memory) {
        return _dopplerData[playerId];
    }
}
