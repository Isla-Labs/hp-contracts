// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";

import {
    AdvancedTradeData,
    DopplerData,
    PlayerSet,
    PlayerStatus,
    TokenData,
    TournamentData,
    VaultData
} from "@types/registries/PlayerSetTypes.sol";

/// @notice Captures graduatePool + minimal PSR surface for MigrationListener tests.
contract MockMigrationPlayerSetRegistry {
    mapping(bytes32 playerId => PlayerSet) internal _sets;
    mapping(address token => bytes32 playerId) public playerIdOfToken;

    uint256 public graduateCount;
    bytes32 public lastGraduatedPlayerId;
    PoolKey public lastGraduatedPool;
    bool public graduateRevert;

    function seedBonding(
        bytes32 playerId,
        address token,
        address hookDoppler,
        address hookMigrator,
        address feeRouter
    ) external {
        playerIdOfToken[token] = playerId;
        PoolKey memory bonding = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookDoppler)
        });
        _sets[playerId] = PlayerSet({
            status: PlayerStatus.BONDING,
            tokenData: TokenData({ token: token, name: "P", symbol: "P" }),
            tournamentData: TournamentData({ leagueId: bytes32(uint256(1)), activeTournaments: new bytes32[](0) }),
            dopplerData: DopplerData({
                activePool: bonding, hookDoppler: hookDoppler, hookMigrator: hookMigrator, feeRouter: feeRouter
            }),
            vaultData: VaultData({ playerVault: address(0), stToken: address(0), isUtilized: false }),
            advancedTradeData: AdvancedTradeData({ advancedTradeVault: address(0), markSource: address(0) })
        });
    }

    function setStatus(bytes32 playerId, PlayerStatus status) external {
        _sets[playerId].status = status;
    }

    function setGraduateRevert(bool v) external {
        graduateRevert = v;
    }

    function getPlayerSet(bytes32 playerId) external view returns (PlayerSet memory) {
        return _sets[playerId];
    }

    function graduatePool(bytes32 playerId, PoolKey calldata activePool) external {
        if (graduateRevert) revert("graduate-fail");
        PlayerSet storage set = _sets[playerId];
        if (address(activePool.hooks) != set.dopplerData.hookMigrator) revert("bad-hooks");
        set.dopplerData.activePool = activePool;
        set.status = PlayerStatus.GRADUATED;
        lastGraduatedPlayerId = playerId;
        lastGraduatedPool = activePool;
        unchecked {
            ++graduateCount;
        }
    }
}

contract MockDopplerConfigModules {
    address public airlock;
    address public poolInitializer;
    address public liquidityMigrator;

    function set(address airlock_, address poolInitializer_, address liquidityMigrator_) external {
        airlock = airlock_;
        poolInitializer = poolInitializer_;
        liquidityMigrator = liquidityMigrator_;
    }
}

contract MockDopplerHookInitializer {
    struct State {
        address numeraire;
        uint256 totalTokensOnBondingCurve;
        address dopplerHook;
        bytes graduationDopplerHookCalldata;
        uint8 status;
        PoolKey poolKey;
        int24 farTick;
    }

    mapping(address asset => State) internal _state;

    function getState(address asset)
        external
        view
        returns (
            address numeraire,
            uint256 totalTokensOnBondingCurve,
            address dopplerHook,
            bytes memory graduationDopplerHookCalldata,
            uint8 status,
            PoolKey memory poolKey,
            int24 farTick
        )
    {
        State storage s = _state[asset];
        return (
            s.numeraire,
            s.totalTokensOnBondingCurve,
            s.dopplerHook,
            s.graduationDopplerHookCalldata,
            s.status,
            s.poolKey,
            s.farTick
        );
    }

    function setState(address asset, uint8 status, PoolKey calldata poolKey, int24 farTick) external {
        _state[asset] = State({
            numeraire: address(0),
            totalTokensOnBondingCurve: 0,
            dopplerHook: address(0),
            graduationDopplerHookCalldata: "",
            status: status,
            poolKey: poolKey,
            farTick: farTick
        });
    }

    function setStatus(address asset, uint8 status) external {
        _state[asset].status = status;
    }
}

contract MockAirlockMigrate {
    mapping(address asset => bool) public shouldRevert;
    mapping(address asset => uint256) public migrateCount;
    address public initializer;

    function setInitializer(address initializer_) external {
        initializer = initializer_;
    }

    function setShouldRevert(address asset, bool v) external {
        shouldRevert[asset] = v;
    }

    function migrate(address asset) external {
        if (shouldRevert[asset]) revert("migrate-fail");
        unchecked {
            ++migrateCount[asset];
        }
        // Flip bonding → exited like Airlock.exitLiquidity path.
        MockDopplerHookInitializer(initializer).setStatus(asset, 4);
    }
}

contract MockDopplerHookMigrator {
    struct Pair {
        address token0;
        address token1;
    }

    mapping(address asset => Pair) internal _pair;
    mapping(address token0 => mapping(address token1 => PoolKey)) internal _poolKey;

    function setPairAndPool(address asset, address token0, address token1, PoolKey calldata poolKey) external {
        _pair[asset] = Pair({ token0: token0, token1: token1 });
        _poolKey[token0][token1] = poolKey;
    }

    function getPair(address asset) external view returns (address token0, address token1) {
        Pair memory p = _pair[asset];
        return (p.token0, p.token1);
    }

    function getAssetData(
        address token0,
        address token1
    )
        external
        view
        returns (
            bool isToken0,
            PoolKey memory poolKey,
            uint32 lockDuration,
            uint24 feeOrInitialDynamicFee,
            bool useDynamicFee,
            address dopplerHook,
            bytes memory onInitializationCalldata,
            uint8 status
        )
    {
        return (true, _poolKey[token0][token1], 0, 0, false, address(0), "", 2);
    }
}
