// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { IPlayerVault } from "../../src/vaults/interfaces/IPlayerVault.sol";
import { IPlayerVaultFactory } from "../../src/vaults/interfaces/IPlayerVaultFactory.sol";
import { PlayerVault } from "../../src/vaults/PlayerVault.sol";
import { PlayerVaultFactory } from "../../src/vaults/PlayerVaultFactory.sol";
import { IAdvancedTradeVault } from "../../src/markets/advanced-updated/interfaces/IAdvancedTradeVault.sol";
import { AdvancedTradeVault } from "../../src/markets/advanced-updated/AdvancedTradeVault.sol";
import { AdvancedTradeVaultFactory } from "../../src/markets/advanced-updated/AdvancedTradeVaultFactory.sol";
import { LongCloseMode, SEEDED_INVENTORY, SlippageBound } from "../../src/markets/advanced-updated/types/AdvancedTradeTypes.sol";
import { MockERC20, MockMarkSource } from "../advanced/mocks/AdvancedTradeMocks.sol";

contract PlayerVaultWireframeTest is Test {
    MockERC20 player;
    MockERC20 usdc;
    MockMarkSource mark;
    AdvancedTradeVaultFactory atFactory;
    AdvancedTradeVault atVault;
    PlayerVaultFactory pvFactory;
    PlayerVault pv;

    address alice = makeAddr("alice");
    address owner = address(this);

    function setUp() public {
        player = new MockERC20("Player", "PLY");
        usdc = new MockERC20("USD Coin", "USDC");
        mark = new MockMarkSource(1e18);

        AdvancedTradeVault impl = new AdvancedTradeVault();
        atFactory = new AdvancedTradeVaultFactory(owner, address(impl));
        player.mint(owner, SEEDED_INVENTORY);
        player.approve(address(atFactory), SEEDED_INVENTORY);
        atVault = AdvancedTradeVault(
            atFactory.create(address(player), address(usdc), address(0), address(mark), address(0), makeAddr("pbr"), 0)
        );
        atVault.updateMark();

        pvFactory = new PlayerVaultFactory(owner);
        pv = PlayerVault(pvFactory.create(address(player)));

        atVault.setPlayerVault(address(pv));
        pv.setAdvancedTradeVault(address(atVault));

        player.mint(alice, 1000 ether);
        vm.prank(alice);
        player.approve(address(pv), type(uint256).max);
        vm.prank(alice);
        player.approve(address(atVault), type(uint256).max);
    }

    function test_factoryCreatesVaultAndStToken() public view {
        assertEq(pvFactory.vaultOf(address(player)), address(pv));
        assertTrue(pv.stToken() != address(0));
        assertEq(pv.playerToken(), address(player));
        assertTrue(pv.isUtilized());
    }

    function test_stakeUnstake_roundTrip() public {
        vm.startPrank(alice);
        pv.stake(100 ether);
        assertEq(pv.stakedBalance(alice), 100 ether);
        assertEq(pv.totalStaked(), 100 ether);

        pv.unstake(40 ether);
        assertEq(pv.stakedBalance(alice), 60 ether);
        assertEq(player.balanceOf(alice), 940 ether);
        vm.stopPrank();
    }

    function test_atOpenLongTokens_revertsWhenStaked() public {
        vm.startPrank(alice);
        pv.stake(50 ether);
        vm.expectRevert(IAdvancedTradeVault.StakedInPlayerVault.selector);
        atVault.openLongTokens(10 ether);
        vm.stopPrank();
    }

    function test_stake_revertsWhenEscrowedInAt() public {
        vm.startPrank(alice);
        atVault.openLongTokens(25 ether);
        assertEq(atVault.accountLongSize(alice), 25 ether);

        vm.expectRevert(IPlayerVault.EscrowedInAdvancedTrade.selector);
        pv.stake(10 ether);
        vm.stopPrank();
    }

    function test_manualReallocation_unstakeThenTokenDeposit() public {
        vm.startPrank(alice);
        pv.stake(80 ether);
        pv.unstake(80 ether);
        uint256 posId = atVault.openLongTokens(80 ether);
        assertEq(pv.stakedBalance(alice), 0);
        assertEq(atVault.accountLongSize(alice), 80 ether);
        assertEq(posId, 1);
        vm.stopPrank();
    }

    function test_manualReallocation_returnTokensThenStake() public {
        vm.startPrank(alice);
        uint256 posId = atVault.openLongTokens(60 ether);
        atVault.closeLong(
            posId,
            LongCloseMode.RETURN_TOKENS,
            SlippageBound({ amountOutMin: 0, amountInMax: 0, deadline: block.timestamp + 1 })
        );
        assertEq(atVault.accountLongSize(alice), 0);

        pv.stake(60 ether);
        assertEq(pv.stakedBalance(alice), 60 ether);
        vm.stopPrank();
    }

    function test_create_revertsDuplicate() public {
        vm.expectRevert(IPlayerVaultFactory.VaultAlreadyExists.selector);
        pvFactory.create(address(player));
    }
}
