// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";

import { AssetRegistry } from "../../src/AssetRegistry.sol";
import {
    AdvancedTradeData,
    AssetData,
    MarketStatus,
    PlayerVaultData,
    RegistryData,
    SpotMarketData
} from "@base/global/types/AssetTypes.sol";
import { HPSwapRouter } from "../../src/routers/HPSwapRouter.sol";
import { HPStakeRouter } from "../../src/routers/HPStakeRouter.sol";
import { IHPStakeRouter } from "../../src/routers/interfaces/IHPStakeRouter.sol";
import { PlayerVault } from "../../src/vaults/PlayerVault.sol";
import { PlayerVaultFactory } from "../../src/vaults/PlayerVaultFactory.sol";
import { IPlayerVault } from "../../src/vaults/interfaces/IPlayerVault.sol";
import { AdvancedTradeVault } from "../../src/markets/advanced-updated/AdvancedTradeVault.sol";
import { AdvancedTradeVaultFactory } from "../../src/markets/advanced-updated/AdvancedTradeVaultFactory.sol";
import { SEEDED_INVENTORY } from "../../src/markets/advanced-updated/types/AdvancedTradeTypes.sol";
import { MockERC20, MockMarkSource } from "../advanced/mocks/AdvancedTradeMocks.sol";

contract HPStakeRouterTest is Test {
    AssetRegistry registry;
    HPStakeRouter stakeRouter;
    PlayerVault pv;
    MockERC20 player;
    MockERC20 usdc;
    AdvancedTradeVault atVault;

    address alice = makeAddr("alice");
    address owner = address(this);

    function setUp() public {
        player = new MockERC20("Player", "PLY");
        usdc = new MockERC20("USDC", "USDC");
        registry = new AssetRegistry(address(this));

        PlayerVaultFactory pvFactory = new PlayerVaultFactory(owner);
        pv = PlayerVault(pvFactory.create(address(player)));

        AdvancedTradeVault impl = new AdvancedTradeVault();
        AdvancedTradeVaultFactory atFactory = new AdvancedTradeVaultFactory(owner, address(impl));
        MockMarkSource mark = new MockMarkSource(1e18);
        player.mint(owner, SEEDED_INVENTORY);
        player.approve(address(atFactory), SEEDED_INVENTORY);
        atVault = AdvancedTradeVault(
            atFactory.create(address(player), address(usdc), address(0), address(mark), address(0), makeAddr("pbr"), 0)
        );
        atVault.updateMark();
        atVault.setPlayerVault(address(pv));
        pv.setAdvancedTradeVault(address(atVault));

        _register(address(player), address(pv));

        stakeRouter = new HPStakeRouter(registry);

        player.mint(alice, 1_000 ether);
        vm.prank(alice);
        player.approve(address(stakeRouter), type(uint256).max);
    }

    function test_stakeUnstake_viaRouter() public {
        vm.startPrank(alice);
        stakeRouter.stake(address(player), 100 ether);
        assertEq(pv.stakedBalance(alice), 100 ether);
        assertEq(player.balanceOf(alice), 900 ether);

        address st = pv.stToken();
        IERC20Approve(st).approve(address(stakeRouter), type(uint256).max);
        stakeRouter.unstake(address(player), 40 ether);
        assertEq(pv.stakedBalance(alice), 60 ether);
        assertEq(player.balanceOf(alice), 940 ether);
        vm.stopPrank();
    }

    function test_stake_revertsWhenUserEscrowed() public {
        vm.startPrank(alice);
        player.approve(address(atVault), type(uint256).max);
        atVault.openLongTokens(10 ether);

        vm.expectRevert(IPlayerVault.EscrowedInAdvancedTrade.selector);
        stakeRouter.stake(address(player), 1 ether);
        vm.stopPrank();
    }

    function test_vaultOf_revertsUnknown() public {
        vm.expectRevert(IHPStakeRouter.VaultNotRegistered.selector);
        stakeRouter.vaultOf(makeAddr("unknown"));
    }

    function _register(address token, address vault) internal {
        address a = token;
        address b = address(usdc);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(uint160(a) < uint160(b) ? a : b),
            currency1: Currency.wrap(uint160(a) < uint160(b) ? b : a),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        AssetData memory data;
        data.playerId = bytes32("p");
        data.leagueId = bytes32("l");
        data.token = token;
        data.symbol = "PLY";
        data.marketStatus = MarketStatus.GRADUATED;
        data.registryData = RegistryData({
            spotMarketData: SpotMarketData({
                activePool: key,
                hookDoppler: address(0),
                hookMigrator: address(0),
                feeRouter: address(0)
            }),
            advancedTradeData: AdvancedTradeData({ advancedTradeVault: address(atVault), markSource: address(0) }),
            playerVaultData: PlayerVaultData({
                playerVault: vault,
                stToken: PlayerVault(vault).stToken(),
                isUtilized: true
            }),
            deployedAt: block.timestamp,
            graduatedAt: block.timestamp,
            deactivatedAt: 0
        });
        registry.createAsset(token, data);
    }
}

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

contract HPSwapRouterWireframeTest is Test {
    AssetRegistry registry;
    HPSwapRouter swapRouter;
    MockERC20 player;
    MockERC20 usdc;

    function setUp() public {
        player = new MockERC20("Player", "PLY");
        usdc = new MockERC20("USDC", "USDC");
        registry = new AssetRegistry(address(this));
        swapRouter = new HPSwapRouter(registry, IPoolManager(makeAddr("pm")));

        address t0 = address(usdc);
        address t1 = address(player);
        if (uint160(t0) > uint160(t1)) (t0, t1) = (t1, t0);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        AssetData memory data;
        data.playerId = bytes32("player");
        data.leagueId = bytes32("league");
        data.token = address(player);
        data.symbol = "PLY";
        data.marketStatus = MarketStatus.GRADUATED;
        data.registryData = RegistryData({
            spotMarketData: SpotMarketData({
                activePool: key,
                hookDoppler: address(0),
                hookMigrator: address(0),
                feeRouter: address(0)
            }),
            advancedTradeData: AdvancedTradeData({ advancedTradeVault: address(0), markSource: address(0) }),
            playerVaultData: PlayerVaultData({ playerVault: address(0), stToken: address(0), isUtilized: false }),
            deployedAt: block.timestamp,
            graduatedAt: 0,
            deactivatedAt: 0
        });
        registry.createAsset(address(player), data);
    }

    function test_swapExactIn_revertsOnExpiredDeadline() public {
        vm.expectRevert(HPSwapRouter.DeadlineExpired.selector);
        swapRouter.swapExactIn(address(usdc), address(player), 1 ether, 1, block.timestamp - 1);
    }

    function test_swapExactIn_revertsOnUnknownPair() public {
        vm.expectRevert(HPSwapRouter.InvalidPair.selector);
        swapRouter.swapExactIn(address(usdc), makeAddr("other"), 1 ether, 1, block.timestamp + 1);
    }

    function test_swapExactOut_revertsOnZeroAmount() public {
        vm.expectRevert(HPSwapRouter.ZeroAmount.selector);
        swapRouter.swapExactOut(address(usdc), address(player), 0, 1, block.timestamp + 1);
    }
}
