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
        treasury = _deployTreasury(TOURNAMENT, SEASON);
        _registerVault(treasury, address(vault));

        startTime = uint64(block.timestamp + 1 days);
        endTime = uint64(block.timestamp + 8 days);
        _publishRound(TOURNAMENT, SEASON, 1, startTime, endTime, 10);
    }

    // --------------------------------------------
    //  Stake / unstake
    // --------------------------------------------

    function test_stake_mintsOneToOne_andUtilization() public {
        _stake(user, vault, 10 ether);

        assertEq(stToken.balanceOf(user), 10 ether);
        assertEq(playerToken.balanceOf(address(vault)), 10 ether);
        assertEq(vault.totalStaked(), 10 ether);
        assertTrue(playerSetRegistry.lastUtilized());
        assertEq(playerSetRegistry.updateCount(), 1);
        assertEq(playerSetRegistry.lastCaller(), address(vault));
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
        assertEq(playerSetRegistry.updateCount(), 2);
    }

    function test_unstake_revertsInsufficient() public {
        _stake(user, vault, 1 ether);
        vm.prank(user);
        vm.expectRevert(Errors.InsufficientStake.selector);
        vault.unstake(2 ether);
    }

    function test_unstake_allowedWhenInactive() public {
        _stake(user, vault, 5 ether);
        vm.prank(orchestrator);
        vault.setActive(false);

        vm.prank(user);
        vault.unstake(5 ether);
        assertEq(playerToken.balanceOf(user), 5 ether);
    }

    function test_unstake_matchweekLock() public {
        _stake(user, vault, 10 ether);

        vm.warp(startTime);
        _sendEth(address(treasury), 100 ether);
        _lockAndSnapshot(treasury);

        assertEq(vault.lockedBalance(user), 10 ether);

        vm.prank(user);
        vm.expectRevert(Errors.MatchweekLock.selector);
        vault.unstake(1 ether);

        // After settle (Claimable), lock lifts.
        vm.warp(endTime);
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 100;
        _settle(treasury, vaults, points, 100);

        assertEq(uint8(treasury.getRound(SEASON, 1).status), uint8(RoundStatus.Claimable));
        assertEq(vault.lockedBalance(user), 0);

        vm.prank(user);
        vault.unstake(10 ether);
    }

    // --------------------------------------------
    //  Snapshot
    // --------------------------------------------

    function test_snapshot_onlyTreasury() public {
        _stake(user, vault, 1 ether);
        vm.expectRevert(Errors.OnlyTournamentTreasury.selector);
        vault.snapshot(TOURNAMENT, SEASON, 1);
    }

    function test_snapshot_unutilizedReturnsFalse() public {
        vm.prank(address(treasury));
        (uint256 snapId, bool didSnap) = vault.snapshot(TOURNAMENT, SEASON, 1);
        assertEq(snapId, 0);
        assertFalse(didSnap);
    }

    function test_snapshot_idempotentForTreasury() public {
        _stake(user, vault, 1 ether);
        vm.warp(startTime);
        _sendEth(address(treasury), 10 ether);
        treasury.lock();
        treasury.snapshotBatch();

        vm.prank(address(treasury));
        (uint256 snapId, bool didSnap) = vault.snapshot(TOURNAMENT, SEASON, 1);
        assertEq(snapId, 1);
        assertTrue(didSnap);
    }

    function test_snapshot_worksWhilePaused() public {
        _stake(user, vault, 1 ether);
        vm.prank(orchestrator);
        vault.pause();

        vm.warp(startTime);
        _sendEth(address(treasury), 10 ether);
        _lockAndSnapshot(treasury);

        assertEq(vault.snapIdOf(TOURNAMENT, SEASON, 1), 1);
    }

    // --------------------------------------------
    //  Claim
    // --------------------------------------------

    function test_claim_happyPath() public {
        _stake(user, vault, 10 ether);
        _runRoundToClaimable(100, 100);

        uint256 preview = treasury.previewClaim(SEASON, 1, address(vault), 10 ether, 10 ether);
        // R = 80% of 100 ether = 80 ether; I = 80 * 100/100 * 10/10 = 80 ether
        assertEq(preview, 80 ether);

        uint256 beforeBal = user.balance;
        vm.prank(user);
        uint256 payout = vault.claim(TOURNAMENT, SEASON, 1);
        assertEq(payout, 80 ether);
        assertEq(user.balance, beforeBal + 80 ether);
    }

    function test_claim_alreadyClaimed() public {
        _stake(user, vault, 10 ether);
        _runRoundToClaimable(100, 100);

        vm.prank(user);
        vault.claim(TOURNAMENT, SEASON, 1);

        vm.prank(user);
        vm.expectRevert(Errors.AlreadyClaimed.selector);
        vault.claim(TOURNAMENT, SEASON, 1);
    }

    function test_claim_nothingToClaim_revertDoesNotPersistClaimed() public {
        _stake(user, vault, 10 ether);
        // Settle with m=0 → claim() reverts NothingToClaim; the pre-revert
        // `_setClaimed` is rolled back, so a retry hits the same error.
        _runRoundToClaimable(0, 100);

        vm.prank(user);
        vm.expectRevert(Errors.NothingToClaim.selector);
        vault.claim(TOURNAMENT, SEASON, 1);

        vm.prank(user);
        vm.expectRevert(Errors.NothingToClaim.selector);
        vault.claim(TOURNAMENT, SEASON, 1);
    }

    function test_claimAll_zeroPoints_marksClaimed() public {
        _stake(user, vault, 10 ether);
        _runRoundToClaimable(0, 100);

        // claimAll uses revertOnEmpty=false, so the claimed bit sticks.
        vm.prank(user);
        assertEq(vault.claimAll(), 0);

        vm.prank(user);
        vm.expectRevert(Errors.AlreadyClaimed.selector);
        vault.claim(TOURNAMENT, SEASON, 1);
    }

    function test_claimAll_skipsNonClaimable() public {
        _stake(user, vault, 10 ether);
        vm.warp(startTime);
        _sendEth(address(treasury), 100 ether);
        _lockAndSnapshot(treasury);

        // Still Locked — claimAll should no-op.
        vm.prank(user);
        uint256 payout = vault.claimAll();
        assertEq(payout, 0);

        vm.warp(endTime);
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 100;
        _settle(treasury, vaults, points, 100);

        vm.prank(user);
        payout = vault.claimAll();
        assertEq(payout, 80 ether);
    }

    function test_claim_revertsPaused() public {
        _stake(user, vault, 10 ether);
        _runRoundToClaimable(100, 100);

        vm.prank(orchestrator);
        vault.pause();

        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.claim(TOURNAMENT, SEASON, 1);
    }

    // --------------------------------------------
    //  Lifecycle / access
    // --------------------------------------------

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

    // --------------------------------------------
    //  Helpers
    // --------------------------------------------

    function _runRoundToClaimable(uint256 vaultPoints, uint256 mAdj) internal {
        vm.warp(startTime);
        _sendEth(address(treasury), 100 ether);
        _lockAndSnapshot(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = vaultPoints;
        _settle(treasury, vaults, points, mAdj);
    }
}
