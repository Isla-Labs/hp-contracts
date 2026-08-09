// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AddressKeys as Addresses } from "@addresses/AddressKeys.sol";
import { RoutersErrors as RouterErrors } from "@errors/routers/RoutersErrors.sol";
import { VaultsErrors as Errors } from "@errors/vaults/VaultsErrors.sol";
import { StakeRouter } from "@routers/StakeRouter.sol";
import { PlayerVault } from "@vaults/PlayerVault.sol";
import { PbrTreasury } from "@vaults/PbrTreasury.sol";
import { StakedToken } from "@vaults/StakedToken.sol";

import { VaultsTestBase } from "../vaults/VaultsTestBase.sol";

contract StakeRouterTest is VaultsTestBase {
    PlayerVault internal vault;
    StakedToken internal stToken;
    PbrTreasury internal treasury;
    StakeRouter internal router;

    uint64 internal startTime;
    uint64 internal endTime;

    function setUp() public override {
        super.setUp();

        // Vault caches STAKE_ROUTER at initialize — register router before deploy.
        router = new StakeRouter(address(ap));
        ap.setName(Addresses.STAKE_ROUTER, address(router));

        (vault, stToken) = _deployVault(PLAYER);
        treasury = _deployTreasury(TOURNAMENT, START_YEAR);
        _registerVault(treasury, address(vault));

        playerSetRegistry.setPlayerToken(PLAYER, address(playerToken));
        playerSetRegistry.setVaultData(PLAYER, address(vault), address(stToken));

        startTime = uint64(block.timestamp + 1 days);
        endTime = uint64(block.timestamp + 8 days);
        _publishRound(TOURNAMENT, START_YEAR, 1, startTime, endTime, 10);
    }

    function test_stake_viaRouter_mintsToUser() public {
        playerToken.mint(user, 10 ether);
        vm.startPrank(user);
        playerToken.approve(address(vault), 10 ether);
        router.stake(address(playerToken), 10 ether);
        vm.stopPrank();

        assertEq(stToken.balanceOf(user), 10 ether);
        assertEq(stToken.balanceOf(address(router)), 0);
        assertEq(playerToken.balanceOf(address(vault)), 10 ether);
        assertEq(vault.totalStaked(), 10 ether);
    }

    function test_unstake_viaRouter_returnsToUser() public {
        _stakeViaRouter(user, 10 ether);

        vm.prank(user);
        router.unstake(address(playerToken), 4 ether);

        assertEq(stToken.balanceOf(user), 6 ether);
        assertEq(playerToken.balanceOf(user), 4 ether);
        assertEq(vault.totalStaked(), 6 ether);
    }

    function test_claim_viaRouter_paysUser() public {
        _stakeViaRouter(user, 10 ether);
        _runRoundToClaimable(100);

        uint256 beforeBal = user.balance;
        vm.prank(user);
        uint256 payout = router.claim(address(playerToken));
        assertEq(payout, 80 ether);
        assertEq(user.balance, beforeBal + 80 ether);
    }

    function test_stakeFor_onlyStakeRouter() public {
        playerToken.mint(user, 1 ether);
        vm.startPrank(user);
        playerToken.approve(address(vault), 1 ether);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.stakeFor(user, 1 ether);
        vm.stopPrank();
    }

    function test_unstakeFor_onlyStakeRouter() public {
        _stake(user, vault, 1 ether);
        vm.prank(user);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.unstakeFor(user, 1 ether);
    }

    function test_claimFor_onlyStakeRouter() public {
        _stake(user, vault, 1 ether);
        _runRoundToClaimable(100);
        vm.prank(user);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.claimFor(user);
    }

    function test_vaultOf_resolves() public view {
        assertEq(router.vaultOf(address(playerToken)), address(vault));
    }

    function test_stake_revertsUnknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(RouterErrors.UnknownToken.selector, address(0xBEEF)));
        router.stake(address(0xBEEF), 1 ether);
    }

    function _stakeViaRouter(address who, uint256 amount) internal {
        playerToken.mint(who, amount);
        vm.startPrank(who);
        playerToken.approve(address(vault), amount);
        router.stake(address(playerToken), amount);
        vm.stopPrank();
    }

    function _runRoundToClaimable(uint256 points) internal {
        _sendEth(address(treasury), 100 ether);
        vm.warp(startTime);
        _lockVaults(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory pts = new uint256[](1);
        pts[0] = points;
        _settle(treasury, vaults, pts);
    }
}
