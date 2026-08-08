// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Math } from "@openzeppelin/utils/math/Math.sol";

import { VaultsErrors as Errors } from "@errors/vaults/VaultsErrors.sol";
import { RoundStatus } from "@types/vaults/VaultTypes.sol";
import { PlayerVault } from "@vaults/PlayerVault.sol";
import { PbrTreasury } from "@vaults/PbrTreasury.sol";

import { VaultsTestBase } from "./VaultsTestBase.sol";
import { MockPlayerToken } from "./mocks/MockPlayerToken.sol";

contract PbrTreasuryTest is VaultsTestBase {
    PlayerVault internal vault;
    PlayerVault internal vault2;
    PbrTreasury internal treasury;

    uint64 internal startTime;
    uint64 internal endTime;

    function setUp() public override {
        super.setUp();
        (vault,) = _deployVault(PLAYER);
        (vault2,) = _deployVault(keccak256("player-2"));
        treasury = _deployTreasury(TOURNAMENT, SEASON);
        _registerVault(treasury, address(vault));

        startTime = uint64(block.timestamp + 1 days);
        endTime = uint64(block.timestamp + 8 days);
        _publishRound(TOURNAMENT, SEASON, 1, startTime, endTime, 10);
    }

    // --------------------------------------------
    //  Accrual / cache
    // --------------------------------------------

    function test_receive_accruesRewards() public {
        _sendEth(address(treasury), 5 ether);
        assertEq(treasury.rewardsR(), 5 ether);
        assertEq(treasury.totalRewardsR(), 5 ether);

        _sendEth(address(treasury), 0);
        assertEq(treasury.rewardsR(), 5 ether);
    }

    function test_syncRegister_revertsUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        treasury.syncRegisterVault(address(vault2));
    }

    function test_syncRegister_duplicateReverts() public {
        vm.prank(address(tournamentRegistry));
        vm.expectRevert(abi.encodeWithSelector(Errors.VaultAlreadyRegistered.selector, address(vault)));
        treasury.syncRegisterVault(address(vault));
    }

    function test_syncUnregister_swapRemove() public {
        _registerVault(treasury, address(vault2));
        assertEq(treasury.getVaults().length, 2);

        vm.prank(address(tournamentRegistry));
        treasury.syncUnregisterVault(address(vault));

        address[] memory vaults = treasury.getVaults();
        assertEq(vaults.length, 1);
        assertEq(vaults[0], address(vault2));
        assertFalse(treasury.isVault(address(vault)));
        assertTrue(treasury.isVault(address(vault2)));
    }

    function test_syncUnregister_unknownReverts() public {
        vm.prank(address(tournamentRegistry));
        vm.expectRevert(abi.encodeWithSelector(Errors.UnknownVault.selector, address(vault2)));
        treasury.syncUnregisterVault(address(vault2));
    }

    // --------------------------------------------
    //  Lock
    // --------------------------------------------

    function test_lock_nonFinal_locks80Percent() public {
        _sendEth(address(treasury), 100 ether);
        vm.warp(startTime);
        treasury.lock();

        assertEq(treasury.getRound(SEASON, 1).R, 80 ether);
        assertEq(treasury.rewardsR(), 20 ether);
        assertEq(uint8(treasury.getRound(SEASON, 1).status), uint8(RoundStatus.Locked));
        assertEq(treasury.tradingRound(), 2);
        assertTrue(treasury.snapshotPending());
    }

    function test_lock_final_locks100Percent_resetsTradingRound() public {
        _publishRound(TOURNAMENT, SEASON, 1, startTime, endTime, 1);
        _sendEth(address(treasury), 50 ether);
        vm.warp(startTime);
        treasury.lock();

        assertEq(treasury.getRound(SEASON, 1).R, 50 ether);
        assertEq(treasury.rewardsR(), 0);
        assertEq(treasury.tradingRound(), 1);
    }

    function test_lock_revertsBeforeStart() public {
        _sendEth(address(treasury), 1 ether);
        vm.expectRevert(Errors.NothingDue.selector);
        treasury.lock();
    }

    function test_lock_revertsUnpublished() public {
        tournamentRegistry.setRound(TOURNAMENT, SEASON, 1, startTime, endTime, false);
        vm.warp(startTime);
        vm.expectRevert(Errors.NothingDue.selector);
        treasury.lock();
    }

    function test_lock_revertsWhenAlreadyLocked() public {
        _sendEth(address(treasury), 1 ether);
        vm.warp(startTime);
        treasury.lock();
        vm.expectRevert(Errors.NothingDue.selector);
        treasury.lock();
    }

    // --------------------------------------------
    //  Snapshot batch
    // --------------------------------------------

    function test_snapshotBatch_snapshotsVault() public {
        _stake(user, vault, 3 ether);
        _sendEth(address(treasury), 10 ether);
        vm.warp(startTime);
        treasury.lock();

        (uint256 processed, bool done) = treasury.snapshotBatch();
        assertEq(processed, 1);
        assertTrue(done);
        assertFalse(treasury.snapshotPending());
        assertEq(vault.snapIdOf(TOURNAMENT, SEASON, 1), 1);
    }

    function test_snapshotBatch_emptyVaults_done() public {
        vm.prank(address(tournamentRegistry));
        treasury.syncUnregisterVault(address(vault));

        _sendEth(address(treasury), 10 ether);
        vm.warp(startTime);
        treasury.lock();

        (uint256 processed, bool done) = treasury.snapshotBatch();
        assertEq(processed, 0);
        assertTrue(done);
    }

    function test_snapshotBatch_idempotentPerVault() public {
        _stake(user, vault, 1 ether);
        _sendEth(address(treasury), 10 ether);
        vm.warp(startTime);
        treasury.lock();
        treasury.snapshotBatch();

        vm.expectRevert(Errors.NothingToSnapshot.selector);
        treasury.snapshotBatch();
    }

    // --------------------------------------------
    //  Settle
    // --------------------------------------------

    function test_settle_byOrchestratorAndPbrSettle() public {
        _stake(user, vault, 1 ether);
        _sendEth(address(treasury), 100 ether);
        vm.warp(startTime);
        _lockAndSnapshot(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 50;

        vm.prank(pbrSettle);
        treasury.settle(vaults, points, 50);

        assertEq(uint8(treasury.getRound(SEASON, 1).status), uint8(RoundStatus.Claimable));
        assertEq(treasury.getVaultPoints(SEASON, 1, address(vault)), 50);
        assertEq(treasury.activeRound(), 2);
        assertEq(tournamentRegistry.flushCount(), 1);
        assertEq(tournamentRegistry.lastFlushTournamentId(), TOURNAMENT);
    }

    function test_settle_revertsUnauthorized() public {
        _sendEth(address(treasury), 1 ether);
        vm.warp(startTime);
        treasury.lock();
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 1;

        vm.prank(user);
        vm.expectRevert(Errors.Unauthorized.selector);
        treasury.settle(vaults, points, 1);
    }

    function test_settle_revertsLengthMismatch() public {
        _sendEth(address(treasury), 1 ether);
        vm.warp(startTime);
        treasury.lock();
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](0);

        vm.prank(orchestrator);
        vm.expectRevert(Errors.LengthMismatch.selector);
        treasury.settle(vaults, points, 1);
    }

    function test_settle_revertsZeroMAdj() public {
        _sendEth(address(treasury), 1 ether);
        vm.warp(startTime);
        treasury.lock();
        vm.warp(endTime);

        address[] memory vaults = new address[](0);
        uint256[] memory points = new uint256[](0);

        vm.prank(orchestrator);
        vm.expectRevert(Errors.ZeroMAdj.selector);
        treasury.settle(vaults, points, 0);
    }

    function test_settle_revertsRoundNotEnded() public {
        _sendEth(address(treasury), 1 ether);
        vm.warp(startTime);
        treasury.lock();

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 1;

        vm.prank(orchestrator);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.RoundNotEnded.selector, SEASON, uint32(1), uint256(endTime), block.timestamp)
        );
        treasury.settle(vaults, points, 1);
    }

    function test_settle_revertsUnknownVault() public {
        _sendEth(address(treasury), 1 ether);
        vm.warp(startTime);
        treasury.lock();
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault2);
        uint256[] memory points = new uint256[](1);
        points[0] = 1;

        vm.prank(orchestrator);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnknownVault.selector, address(vault2)));
        treasury.settle(vaults, points, 1);
    }

    function test_settle_finalRound_wrapsSeason() public {
        _publishRound(TOURNAMENT, SEASON, 1, startTime, endTime, 1);
        _stake(user, vault, 1 ether);
        _sendEth(address(treasury), 10 ether);
        vm.warp(startTime);
        _lockAndSnapshot(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 10;
        _settle(treasury, vaults, points, 10);

        assertEq(treasury.seasonId(), SEASON + 1);
        assertEq(treasury.activeRound(), 1);
    }

    // --------------------------------------------
    //  payClaim / PBR math
    // --------------------------------------------

    function test_payClaim_pbrFormula() public {
        _stake(user, vault, 25 ether);
        _stake(user2, vault, 75 ether);

        _sendEth(address(treasury), 100 ether);
        vm.warp(startTime);
        _lockAndSnapshot(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 200;
        _settle(treasury, vaults, points, 400);

        uint256 R = 80 ether;
        uint256 expectedUser = Math.mulDiv(Math.mulDiv(R, 200, 400), 25 ether, 100 ether);
        uint256 expectedUser2 = Math.mulDiv(Math.mulDiv(R, 200, 400), 75 ether, 100 ether);

        assertEq(treasury.previewClaim(SEASON, 1, address(vault), 25 ether, 100 ether), expectedUser);

        uint256 before = user.balance;
        vm.prank(user);
        uint256 payout = vault.claim(TOURNAMENT, SEASON, 1);
        assertEq(payout, expectedUser);
        assertEq(user.balance, before + expectedUser);

        before = user2.balance;
        vm.prank(user2);
        payout = vault.claim(TOURNAMENT, SEASON, 1);
        assertEq(payout, expectedUser2);
        assertEq(user2.balance, before + expectedUser2);
    }

    function test_payClaim_unauthorizedVault() public {
        _stake(user, vault, 1 ether);
        _sendEth(address(treasury), 100 ether);
        vm.warp(startTime);
        _lockAndSnapshot(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 10;
        _settle(treasury, vaults, points, 10);

        vm.prank(user);
        vm.expectRevert(Errors.NothingToClaim.selector);
        treasury.payClaim(SEASON, 1, user, 1 ether, 1 ether);
    }

    function test_payClaim_afterUnregister_stillWorks() public {
        _stake(user, vault, 10 ether);
        _sendEth(address(treasury), 100 ether);
        vm.warp(startTime);
        _lockAndSnapshot(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 100;
        _settle(treasury, vaults, points, 100);

        vm.prank(address(tournamentRegistry));
        treasury.syncUnregisterVault(address(vault));
        assertFalse(treasury.isVault(address(vault)));

        vm.prank(user);
        uint256 payout = vault.claim(TOURNAMENT, SEASON, 1);
        assertEq(payout, 80 ether);
    }

    function test_payClaim_transferFailed() public {
        ClaimRevertHelper helper = new ClaimRevertHelper();
        playerToken.mint(address(helper), 10 ether);
        helper.stake(vault, playerToken, 10 ether);

        _sendEth(address(treasury), 100 ether);
        vm.warp(startTime);
        _lockAndSnapshot(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 100;
        _settle(treasury, vaults, points, 100);

        vm.expectRevert(Errors.TransferFailed.selector);
        helper.claim(vault, TOURNAMENT, SEASON, 1);
    }

    function test_previewClaim_capsToRemaining() public {
        _stake(user, vault, 50 ether);
        _stake(user2, vault, 50 ether);
        _sendEth(address(treasury), 100 ether);
        vm.warp(startTime);
        _lockAndSnapshot(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 100;
        _settle(treasury, vaults, points, 100);

        vm.prank(user);
        vault.claim(TOURNAMENT, SEASON, 1);

        uint256 remaining = treasury.getRound(SEASON, 1).R - treasury.getRound(SEASON, 1).paid;
        uint256 preview = treasury.previewClaim(SEASON, 1, address(vault), 50 ether, 100 ether);
        assertEq(preview, remaining);
    }
}

/// @dev Stakes then claims into a contract that rejects ETH.
contract ClaimRevertHelper {
    receive() external payable {
        revert("no eth");
    }

    function stake(PlayerVault vault, MockPlayerToken token, uint256 amount) external {
        token.approve(address(vault), amount);
        vault.stake(amount);
    }

    function claim(PlayerVault vault, bytes32 tournamentId, uint16 season, uint32 round) external {
        vault.claim(tournamentId, season, round);
    }
}
