// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { VaultsErrors as Errors } from "@errors/vaults/VaultsErrors.sol";
import { PlayerVault } from "@vaults/PlayerVault.sol";
import { StakedToken } from "@vaults/StakedToken.sol";

import { VaultsTestBase } from "./VaultsTestBase.sol";

contract StakedTokenTest is VaultsTestBase {
    PlayerVault internal vault;
    StakedToken internal stToken;

    function setUp() public override {
        super.setUp();
        (vault, stToken) = _deployVault(PLAYER);
    }

    function test_mint_burn_onlyVault() public {
        vm.expectRevert(Errors.OnlyVault.selector);
        stToken.mint(user, 1 ether);

        vm.expectRevert(Errors.OnlyVault.selector);
        stToken.burn(user, 1);

        _stake(user, vault, 5 ether);
        assertEq(stToken.balanceOf(user), 5 ether);

        vm.prank(user);
        vault.unstake(2 ether);
        assertEq(stToken.balanceOf(user), 3 ether);
    }

    function test_snapshot_onlyVault() public {
        vm.expectRevert(Errors.OnlyVault.selector);
        stToken.snapshot();
    }

    function test_transfer_p2p_reverts() public {
        _stake(user, vault, 1 ether);
        vm.prank(user);
        vm.expectRevert(Errors.OnlyVault.selector);
        stToken.transfer(user2, 0.5 ether);
    }

    function test_snapshot_balanceOfAt_totalSupplyAt() public {
        _stake(user, vault, 10 ether);

        address fakeTreasury = makeAddr("fakeTreasury");
        tournamentRegistry.setPbrTreasury(TOURNAMENT, fakeTreasury);
        vm.prank(fakeTreasury);
        uint256 snapId = vault.snapshot(TOURNAMENT, SEASON, 1);
        assertEq(snapId, 1);

        assertEq(stToken.balanceOfAt(user, snapId), 10 ether);
        assertEq(stToken.totalSupplyAt(snapId), 10 ether);

        _stake(user2, vault, 4 ether);
        assertEq(stToken.balanceOf(user2), 4 ether);
        assertEq(stToken.balanceOfAt(user2, snapId), 0);
        assertEq(stToken.totalSupplyAt(snapId), 10 ether);
        assertEq(stToken.totalSupply(), 14 ether);
    }
}
