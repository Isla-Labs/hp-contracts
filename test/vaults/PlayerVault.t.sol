// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Pausable } from "@openzeppelin/utils/Pausable.sol";

import { VaultsErrors as Errors } from "@errors/vaults/VaultsErrors.sol";
import { RoundStatus } from "@types/vaults/VaultTypes.sol";
import { PlayerVault } from "@vaults/PlayerVault.sol";
import { PbrTreasury } from "@vaults/PbrTreasury.sol";
import { StakedToken } from "@vaults/StakedToken.sol";

import { VaultsTestBase } from "./VaultsTestBase.sol";

contract PlayerVaultTest is VaultsTestBase {
    PlayerVault internal vault;
    StakedToken internal stToken;
    PbrTreasury internal treasury;

    uint64 internal startTime;
    uint64 internal endTime;

    function setUp() public override {
        super.setUp();
        (vault, stToken) = _deployVault(PLAYER);
        treasury = _deployTreasury(TOURNAMENT, START_YEAR);
        _registerVault(treasury, address(vault));

        startTime = uint64(block.timestamp + 1 days);
        endTime = uint64(block.timestamp + 8 days);
        _publishRound(TOURNAMENT, START_YEAR, 1, startTime, endTime, 10);
    }

    function test_stake_mintsOneToOne_andUtilization() public {
        assertEq(vault.activeTreasuryCount(), 1);
        assertEq(vault.treasuryOf(TOURNAMENT), address(treasury));

        _stake(user, vault, 10 ether);

        assertEq(stToken.balanceOf(user), 10 ether);
        assertEq(playerToken.balanceOf(address(vault)), 10 ether);
        assertEq(vault.totalStaked(), 10 ether);
        assertTrue(playerSetRegistry.lastUtilized());
        assertEq(playerSetRegistry.updateCount(), 1);
        assertEq(treasury.getUtilizedVaults(START_YEAR, 1).length, 1);
    }

    function test_syncActiveTreasury_onlyTournamentRegistry() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.syncActiveTreasury(TOURNAMENT, address(treasury), true);
    }

    function test_stake_revertsZero() public {
        vm.prank(user);
        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.stake(0);
    }

    function test_stake_revertsInactive() public {
        vm.prank(orchestrator);
        vault.setActive(false);

        playerToken.mint(user, 1 ether);
        vm.startPrank(user);
        playerToken.approve(address(vault), 1 ether);
        vm.expectRevert(Errors.VaultInactive.selector);
        vault.stake(1 ether);
        vm.stopPrank();
    }

    function test_stake_revertsPaused() public {
        vm.prank(orchestrator);
        vault.pause();

        playerToken.mint(user, 1 ether);
        vm.startPrank(user);
        playerToken.approve(address(vault), 1 ether);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.stake(1 ether);
        vm.stopPrank();
    }

    function test_unstake_burnsAndTransfers_utilizationDown() public {
        _stake(user, vault, 10 ether);

        vm.prank(user);
        vault.unstake(10 ether);

        assertEq(stToken.balanceOf(user), 0);
        assertEq(playerToken.balanceOf(user), 10 ether);
        assertEq(vault.totalStaked(), 0);
        assertFalse(playerSetRegistry.lastUtilized());
        assertEq(treasury.getUtilizedVaults(START_YEAR, 1).length, 0);
    }

    function test_unstake_revertsInsufficient() public {
        _stake(user, vault, 1 ether);
        vm.prank(user);
        vm.expectRevert(Errors.InsufficientStake.selector);
        vault.unstake(2 ether);
    }

    function test_unstake_matchweekLock() public {
        _stake(user, vault, 10 ether);

        vm.warp(startTime);
        _sendEth(address(treasury), 100 ether);
        _lockVaults(treasury);

        assertEq(vault.lockedBalance(user), 10 ether);

        vm.prank(user);
        vm.expectRevert(Errors.MatchweekLock.selector);
        vault.unstake(1 ether);

        vm.warp(endTime);
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 100;
        _settle(treasury, vaults, points);

        assertEq(uint8(treasury.getRound(START_YEAR, 1).status), uint8(RoundStatus.Claimable));
        assertEq(vault.lockedBalance(user), 0);

        vm.prank(user);
        vault.unstake(10 ether);
    }

    function test_claim_happyPath() public {
        _stake(user, vault, 10 ether);
        _runRoundToClaimable(100);

        uint256 preview = treasury.previewClaim(START_YEAR, 1, address(vault), user);
        assertEq(preview, 80 ether);

        uint256 beforeBal = user.balance;
        vm.prank(user);
        uint256 payout = vault.claim(TOURNAMENT, START_YEAR, 1);
        assertEq(payout, 80 ether);
        assertEq(user.balance, beforeBal + 80 ether);
    }

    function test_claim_alreadyClaimed() public {
        _stake(user, vault, 10 ether);
        _runRoundToClaimable(100);

        vm.prank(user);
        vault.claim(TOURNAMENT, START_YEAR, 1);

        vm.prank(user);
        vm.expectRevert(Errors.AlreadyClaimed.selector);
        vault.claim(TOURNAMENT, START_YEAR, 1);
    }

    function test_claim_nothingToClaim_revertDoesNotPersistClaimed() public {
        _stake(user, vault, 10 ether);
        _runRoundToClaimable(0);

        vm.prank(user);
        vm.expectRevert(Errors.NothingToClaim.selector);
        vault.claim(TOURNAMENT, START_YEAR, 1);

        vm.prank(user);
        vm.expectRevert(Errors.NothingToClaim.selector);
        vault.claim(TOURNAMENT, START_YEAR, 1);
    }

    function test_claimAll_zeroPoints_marksClaimed() public {
        _stake(user, vault, 10 ether);
        _runRoundToClaimable(0);

        vm.prank(user);
        assertEq(vault.claimAll(), 0);

        vm.prank(user);
        vm.expectRevert(Errors.AlreadyClaimed.selector);
        vault.claim(TOURNAMENT, START_YEAR, 1);
    }

    function test_claimAll_skipsNonClaimable() public {
        _stake(user, vault, 10 ether);
        vm.warp(startTime);
        _sendEth(address(treasury), 100 ether);
        _lockVaults(treasury);

        vm.prank(user);
        uint256 payout = vault.claimAll();
        assertEq(payout, 0);

        vm.warp(endTime);
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 100;
        _settle(treasury, vaults, points);

        vm.prank(user);
        payout = vault.claimAll();
        assertEq(payout, 80 ether);
    }

    function test_claim_revertsPaused() public {
        _stake(user, vault, 10 ether);
        _runRoundToClaimable(100);

        vm.prank(orchestrator);
        vault.pause();

        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.claim(TOURNAMENT, START_YEAR, 1);
    }

    function test_setActive_allowsOrchestratorAndPsr() public {
        vm.prank(orchestrator);
        vault.setActive(false);
        assertFalse(vault.isActive());

        vm.prank(address(playerSetRegistry));
        vault.setActive(true);
        assertTrue(vault.isActive());
    }

    function test_setActive_revertsUnauthorized() public {
        vm.prank(user);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.setActive(false);
    }

    function test_pause_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vault.pause();
    }

    function _runRoundToClaimable(uint256 vaultPoints_) internal {
        vm.warp(startTime);
        _sendEth(address(treasury), 100 ether);
        _lockVaults(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = vaultPoints_;
        _settle(treasury, vaults, points);
    }
}
