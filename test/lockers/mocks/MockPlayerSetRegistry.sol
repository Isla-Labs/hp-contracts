// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";

import {
    AdvancedTradeData,
    DopplerData,
    PlayerSet,
    PlayerStatus,
    TokenData,
    TournamentData,
    VaultData
} from "@types/registries/PlayerSetTypes.sol";

/// @notice Locker-grade PlayerSetRegistry stub.
contract MockPlayerSetRegistry {
    mapping(bytes32 playerId => PlayerSet) internal _sets;

    bytes32 public lastStatusPlayerId;
    PlayerStatus public lastStatus;
    uint256 public setStatusCount;

    bytes32 public lastLeaguePlayerId;
    bytes32 public lastNewLeagueId;
    bytes32[] public lastActiveTournaments;
    uint256 public setLeagueIdCount;

    function seedPlayer(
        bytes32 playerId,
        PlayerStatus status,
        bytes32 leagueId,
        address feeRouter,
        address hookDoppler,
        address hookMigrator,
        address activeHooks
    ) external {
        PoolKey memory pool;
        pool.currency0 = Currency.wrap(address(0));
        pool.currency1 = Currency.wrap(address(1));
        pool.fee = 0;
        pool.tickSpacing = 1;
        pool.hooks = IHooks(activeHooks);

        _sets[playerId] = PlayerSet({
            status: status,
            tokenData: TokenData({ token: address(0), name: "", symbol: "" }),
            tournamentData: TournamentData({ leagueId: leagueId, activeTournaments: new bytes32[](0) }),
            dopplerData: DopplerData({
                activePool: pool,
                hookDoppler: hookDoppler,
                hookMigrator: hookMigrator,
                feeRouter: feeRouter
            }),
            vaultData: VaultData({ playerVault: address(0), stToken: address(0), isUtilized: false }),
            advancedTradeData: AdvancedTradeData({ advancedTradeVault: address(0), markSource: address(0) })
        });
    }

    function getPlayerSet(bytes32 playerId) external view returns (PlayerSet memory) {
        return _sets[playerId];
    }

    function getDopplerData(bytes32 playerId) external view returns (DopplerData memory) {
        return _sets[playerId].dopplerData;
    }

    function setStatus(bytes32 playerId, PlayerStatus status) external {
        _sets[playerId].status = status;
        lastStatusPlayerId = playerId;
        lastStatus = status;
        unchecked {
            ++setStatusCount;
        }
    }

    function setLeagueId(bytes32 playerId, bytes32 newLeagueId, bytes32[] calldata activeTournamentIds) external {
        _sets[playerId].tournamentData.leagueId = newLeagueId;
        _sets[playerId].tournamentData.activeTournaments = activeTournamentIds;
        lastLeaguePlayerId = playerId;
        lastNewLeagueId = newLeagueId;
        delete lastActiveTournaments;
        for (uint256 i; i < activeTournamentIds.length; ++i) {
            lastActiveTournaments.push(activeTournamentIds[i]);
        }
        unchecked {
            ++setLeagueIdCount;
        }
    }
}
