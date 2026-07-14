// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";

import { AssetRegistry } from "../../src/AssetRegistry.sol";
import {
    AssetData,
    MarketStatus,
    RegistryData,
    SpotMarketData,
    AdvancedTradeData,
    PlayerVaultData
} from "@base/global/types/AssetTypes.sol";
import { PoolMarkSource } from "../../src/markets/advanced-updated/oracles/PoolMarkSource.sol";
import { PoolLiquiditySource } from "../../src/markets/advanced-updated/oracles/PoolLiquiditySource.sol";
import { PoolImpactEstimator } from "../../src/markets/advanced-updated/oracles/PoolImpactEstimator.sol";
import { IPoolQuoter } from "../../src/markets/advanced-updated/oracles/interfaces/IPoolQuoter.sol";
import { PoolPricing } from "../../src/markets/advanced-updated/oracles/libraries/PoolPricing.sol";

contract PoolReadersDeployTest is Test {
    AssetRegistry registry;
    address player = makeAddr("player");
    address usdc = makeAddr("usdc");
    address pm = makeAddr("poolManager");
    address quoter = makeAddr("quoter");

    function setUp() public {
        registry = new AssetRegistry(address(this));
        // Ensure player > usdc for currency ordering if needed — wrap as currencies sorted
        if (uint160(player) < uint160(usdc)) {
            (player, usdc) = (usdc, player);
        }

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(usdc),
            currency1: Currency.wrap(player),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        AssetData memory data;
        data.playerId = bytes32("p");
        data.leagueId = bytes32("l");
        data.token = player;
        data.symbol = "PLY";
        data.marketStatus = MarketStatus.GRADUATED;
        data.registryData = RegistryData({
            spotMarketData: SpotMarketData({
                activePool: key,
                hookDoppler: address(0),
                hookMigrator: address(0),
                feeRouter: address(0)
            }),
            advancedTradeData: AdvancedTradeData({
                advancedTradeVault: address(0),
                markSource: address(0)
            }),
            playerVaultData: PlayerVaultData({ playerVault: address(0), stToken: address(0), isUtilized: false }),
            deployedAt: block.timestamp,
            graduatedAt: block.timestamp,
            deactivatedAt: 0
        });
        registry.createAsset(player, data);
    }

    function test_deployThreeReaders() public {
        PoolMarkSource mark = new PoolMarkSource(registry, IPoolManager(pm), player);
        PoolLiquiditySource liq = new PoolLiquiditySource(address(this), registry, IPoolManager(pm), 3000e18);
        PoolImpactEstimator impact =
            new PoolImpactEstimator(registry, IPoolManager(pm), IPoolQuoter(quoter));

        assertEq(mark.playerToken(), player);
        assertEq(address(liq.registry()), address(registry));
        assertEq(address(impact.quoter()), quoter);
    }

    function test_poolKeyResolvesPlayer() public view {
        PoolKey memory key = PoolPricing.poolKey(registry, player);
        assertEq(Currency.unwrap(key.currency1), player);
        assertEq(Currency.unwrap(key.currency0), usdc);
        assertTrue(PoolPricing.isPlayerToken0(key, player) == false);
        assertEq(PoolPricing.numeraire(key, player), usdc);
    }

    function test_poolKeyRevertsUnknownToken() public {
        vm.expectRevert(PoolPricing.PoolNotSet.selector);
        this._poolKey(makeAddr("unknown"));
    }

    function _poolKey(address token) external view {
        PoolPricing.poolKey(registry, token);
    }
}
