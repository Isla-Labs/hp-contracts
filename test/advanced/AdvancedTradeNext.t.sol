// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { AdvancedTradeVault } from "../../src/markets/advanced-updated/AdvancedTradeVault.sol";
import { AdvancedTradeVaultFactory } from "../../src/markets/advanced-updated/AdvancedTradeVaultFactory.sol";
import { FundingController } from "../../src/markets/advanced-updated/FundingController.sol";
import { IAdvancedTradeVault } from "../../src/markets/advanced-updated/interfaces/IAdvancedTradeVault.sol";
import { SlippageBound } from "../../src/markets/advanced-updated/types/AdvancedTradeTypes.sol";
import {
    MockERC20,
    MockImpactEstimator,
    MockMarkSource,
    MockPlayerVault,
    MockSwapRouter
} from "./mocks/AdvancedTradeMocks.sol";

contract AdvancedTradeVaultNextTest is Test {
    AdvancedTradeVaultFactory factory;
    IAdvancedTradeVault vault;
    FundingController funding;

    MockERC20 player;
    MockERC20 usdc;
    MockSwapRouter router;
    MockMarkSource markSource;
    MockPlayerVault playerVault;

    address trader = makeAddr("trader");
    address treasury = makeAddr("treasury");

    uint256 constant PRICE = 2e18;

    function setUp() public {
        player = new MockERC20("Player", "PLY");
        usdc = new MockERC20("USD Coin", "USDC");
        router = new MockSwapRouter(PRICE);
        markSource = new MockMarkSource(PRICE);
        playerVault = new MockPlayerVault();
        router.setTokens(address(player), address(usdc));

        AdvancedTradeVault implementation = new AdvancedTradeVault();
        factory = new AdvancedTradeVaultFactory(address(this), address(implementation));
        funding = new FundingController(address(this));

        uint256 seed = 1_000_000 ether;
        player.mint(address(this), seed);
        player.approve(address(factory), seed);
        player.mint(address(router), 50_000_000 ether);
        usdc.mint(address(router), 100_000_000 ether);

        address vaultAddr = factory.create(
            address(player),
            address(usdc),
            address(router),
            address(markSource),
            address(funding),
            treasury,
            seed
        );
        vault = IAdvancedTradeVault(vaultAddr);
        AdvancedTradeVault(address(vault)).setPlayerVault(address(playerVault));

        funding.registerMarket(address(vault), address(player));

        usdc.mint(trader, 5_000_000 ether);
        player.mint(trader, 100_000 ether);
        vm.startPrank(trader);
        usdc.approve(address(vault), type(uint256).max);
        player.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _boundIn(uint256 minOut) internal view returns (SlippageBound memory) {
        return SlippageBound({ amountOutMin: minOut, amountInMax: 0, deadline: block.timestamp + 1 hours });
    }

    function _boundOut(uint256 maxIn) internal view returns (SlippageBound memory) {
        return SlippageBound({ amountOutMin: 0, amountInMax: maxIn, deadline: block.timestamp + 1 hours });
    }

    function test_exclusivity_revertsWhenStaked() public {
        playerVault.setStaked(trader, 1 ether);
        vm.prank(trader);
        vm.expectRevert(IAdvancedTradeVault.StakedInPlayerVault.selector);
        vault.openLongTokens(100 ether);
    }

    function test_impactEstimator_tightensMargin() public {
        MockImpactEstimator est = new MockImpactEstimator(0.5e18); // 50% impact
        AdvancedTradeVault(address(vault)).setImpactEstimator(address(est));

        // With 50% impact haircut, 1000 collateral on 1000 size @ mark 2 is insufficient
        vm.prank(trader);
        vm.expectRevert(IAdvancedTradeVault.InsufficientMargin.selector);
        vault.openShort(1_000 ether, 1_000 ether, _boundIn(1));
    }

    function test_fundingAccruesForCorrectiveLong() public {
        // Exit grace, set ppm/liq so market is undervalued (positive gap → longs earn)
        funding.setPpm(address(vault), 100 ether);
        funding.setLiq(address(vault), 10 ether); // low liq vs target
        funding.setGrace(address(vault), false);

        // Need aggregate LIQ/PPM — single market: target = liq share of itself → gap 0.
        // Add synthetic second market by registering a dummy vault address with higher liq share mismatch.
        address vaultB = makeAddr("vaultB");
        funding.registerMarket(vaultB, makeAddr("tokenB"));
        funding.setPpm(vaultB, 100 ether);
        funding.setLiq(vaultB, 90 ether);
        funding.setGrace(vaultB, false);
        // Now vault A: ppm=100, PPM=200, liq=10, LIQ=100 → L*=50, g=(50-10)/50=0.8 → longs onside

        vm.deal(address(funding), 90 ether);
        funding.resetDrip(90 days);

        funding.remarque(address(vault));
        assertGt(funding.gap(address(vault)), 0);
        assertGt(funding.marketRate(address(vault)), 0);

        vm.prank(trader);
        vault.openLongTokens(1_000 ether);

        vm.warp(block.timestamp + 7 days);
        funding.remarque(address(vault));

        uint256 pending = funding.pendingFunding(address(vault), trader);
        assertGt(pending, 0);

        uint256 before = trader.balance;
        vm.prank(trader);
        uint256 claimed = vault.claimFunding();
        assertEq(claimed, pending);
        assertEq(trader.balance, before + claimed);
    }

    function test_badDebtWriteOffOnLiquidation() public {
        uint256 size = 1_000 ether;
        uint256 collateralIn = 2_000 ether;

        vm.prank(trader);
        (uint256 posId,) = vault.openShort(size, collateralIn, _boundIn(1));

        AdvancedTradeVault(address(vault)).setMarkHalfLife(1);
        // Extreme pump: buyback >> proceeds+collateral; triggers partial buyback path
        router.setPrice(100e18);
        markSource.setSpot(100e18);
        vm.warp(block.timestamp + 1 hours);
        vault.updateMark();
        assertTrue(vault.isLiquidatable(posId));

        uint256 invBefore = vault.inventorySize();
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        vault.liquidate(posId, _boundOut(type(uint128).max));

        assertFalse(vault.getPosition(posId).open);
        assertEq(vault.shortOpenInterest(), 0);
        // Inventory capacity written down by unrecovered tokens
        assertLt(vault.inventorySize(), invBefore);
    }
}
