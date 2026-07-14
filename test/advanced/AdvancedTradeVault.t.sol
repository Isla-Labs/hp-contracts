// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

import { AdvancedTradeVault } from "../../src/markets/advanced-updated/AdvancedTradeVault.sol";
import { AdvancedTradeVaultFactory } from "../../src/markets/advanced-updated/AdvancedTradeVaultFactory.sol";
import { IAdvancedTradeVault } from "../../src/markets/advanced-updated/interfaces/IAdvancedTradeVault.sol";
import {
    LongCloseMode,
    SlippageBound,
    WAD
} from "../../src/markets/advanced-updated/types/AdvancedTradeTypes.sol";
import { MockERC20, MockMarkSource, MockSwapRouter } from "./mocks/AdvancedTradeMocks.sol";

contract AdvancedTradeVaultTest is Test {
    AdvancedTradeVaultFactory factory;
    AdvancedTradeVault implementation;
    IAdvancedTradeVault vault;

    MockERC20 player;
    MockERC20 usdc;
    MockSwapRouter router;
    MockMarkSource markSource;

    address owner = address(this);
    address trader = makeAddr("trader");
    address treasury = makeAddr("treasury");

    uint256 constant PRICE = 2e18; // 2 USDC per player token

    function setUp() public {
        player = new MockERC20("Player", "PLY");
        usdc = new MockERC20("USD Coin", "USDC");
        router = new MockSwapRouter(PRICE);
        markSource = new MockMarkSource(PRICE);
        router.setTokens(address(player), address(usdc));

        implementation = new AdvancedTradeVault();
        factory = new AdvancedTradeVaultFactory(owner, address(implementation));

        uint256 seed = 1_000_000 ether;
        player.mint(owner, seed);
        player.approve(address(factory), seed);

        player.mint(address(router), 10_000_000 ether);
        usdc.mint(address(router), 20_000_000 ether);

        address vaultAddr = factory.create(
            address(player),
            address(usdc),
            address(router),
            address(markSource),
            address(0),
            treasury,
            seed
        );
        vault = IAdvancedTradeVault(vaultAddr);

        usdc.mint(trader, 1_000_000 ether);
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

    function test_inventorySeeded() public view {
        assertEq(vault.inventorySize(), 1_000_000 ether);
        assertEq(vault.idleInventory(), 1_000_000 ether);
        assertEq(vault.markPrice(), PRICE);
        assertEq(IERC20(address(player)).balanceOf(address(vault)), 1_000_000 ether);
    }

    function test_openAndCloseShort_profitWhenPriceFalls() public {
        uint256 size = 1_000 ether;
        uint256 collateralIn = 1_000 ether;

        vm.prank(trader);
        (uint256 posId, uint256 proceeds) = vault.openShort(size, collateralIn, _boundIn(1));
        assertEq(proceeds, (size * PRICE) / WAD);
        assertEq(vault.shortOpenInterest(), size);
        assertEq(vault.idleInventory(), 1_000_000 ether - size);
        assertEq(IERC20(address(player)).balanceOf(address(vault)), 1_000_000 ether - size);

        router.setPrice(1e18);
        markSource.setSpot(1e18);
        vault.updateMark();

        uint256 usdcBefore = usdc.balanceOf(trader);
        vm.prank(trader);
        int256 pnl = vault.closeShort(posId, _boundOut(type(uint128).max));
        assertGt(pnl, 0);
        assertEq(vault.shortOpenInterest(), 0);
        assertEq(IERC20(address(player)).balanceOf(address(vault)), 1_000_000 ether);
        assertGt(usdc.balanceOf(trader), usdcBefore);
    }

    function test_openShort_revertsOnInsufficientMargin() public {
        uint256 size = 1_000 ether;
        uint256 tinyCollateral = 1 ether;

        vm.prank(trader);
        vm.expectRevert(IAdvancedTradeVault.InsufficientMargin.selector);
        vault.openShort(size, tinyCollateral, _boundIn(1));
    }

    function test_openShort_revertsOnHardCap() public {
        vm.prank(trader);
        vm.expectRevert(IAdvancedTradeVault.InsufficientInventory.selector);
        vault.openShort(1_000_001 ether, 1_000_000 ether, _boundIn(1));
    }

    function test_openAndCloseLong_tokenDeposit() public {
        uint256 amount = 500 ether;
        vm.prank(trader);
        uint256 posId = vault.openLongTokens(amount);
        assertEq(vault.getPosition(posId).size, amount);
        assertEq(IERC20(address(player)).balanceOf(address(vault)), 1_000_000 ether + amount);

        vm.prank(trader);
        uint256 out = vault.closeLong(
            posId,
            LongCloseMode.RETURN_TOKENS,
            SlippageBound({ amountOutMin: 0, amountInMax: 0, deadline: block.timestamp + 1 })
        );
        assertEq(out, amount);
        assertEq(IERC20(address(player)).balanceOf(address(vault)), 1_000_000 ether);
    }

    function test_openAndCloseLong_usdcIn() public {
        uint256 usdcIn = 2_000 ether;
        vm.prank(trader);
        (uint256 posId, uint256 size) = vault.openLongUsdc(usdcIn, _boundIn(1));
        assertEq(size, 1_000 ether);

        vm.prank(trader);
        uint256 out = vault.closeLong(posId, LongCloseMode.SELL_TO_USDC, _boundIn(1));
        assertEq(out, 2_000 ether);
    }

    function test_borrowFeeAccruesOverTime() public {
        uint256 size = 1_000 ether;
        uint256 collateralIn = 2_000 ether;

        vm.prank(trader);
        (uint256 posId,) = vault.openShort(size, collateralIn, _boundIn(1));

        uint256 colBefore = vault.getPosition(posId).collateral;
        vm.warp(block.timestamp + 30 days);
        vault.accrueBorrowFee(posId);
        uint256 colAfter = vault.getPosition(posId).collateral;
        assertLt(colAfter, colBefore);
        assertGt(vault.insuranceBuffer(), 0);
    }

    function test_liquidateUnderwaterShort() public {
        uint256 size = 1_000 ether;
        uint256 collateralIn = 2_000 ether;

        vm.prank(trader);
        (uint256 posId,) = vault.openShort(size, collateralIn, _boundIn(1));

        // Fast EMA so spot pump reaches mark in one update
        AdvancedTradeVault(address(vault)).setMarkHalfLife(1);

        router.setPrice(3.5e18);
        markSource.setSpot(3.5e18);
        vm.warp(block.timestamp + 1 hours);
        vault.updateMark();
        assertTrue(vault.isLiquidatable(posId));

        address keeper = makeAddr("keeper");
        usdc.mint(address(router), 10_000_000 ether);
        player.mint(address(router), 10_000_000 ether);

        uint256 keeperBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        vault.liquidate(posId, _boundOut(type(uint128).max));

        assertFalse(vault.getPosition(posId).open);
        assertEq(vault.shortOpenInterest(), 0);
        assertEq(IERC20(address(player)).balanceOf(address(vault)), 1_000_000 ether);
        assertGt(usdc.balanceOf(keeper), keeperBefore);
    }
}
