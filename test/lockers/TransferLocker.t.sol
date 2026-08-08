// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RateLimit } from "@base/abstract/RateLimit.sol";
import { LifecycleErrors as Errors } from "@errors/lockers/LifecycleErrors.sol";
import { LifecycleQueueStatus, LifecycleReason, PendingLifecycle } from "@types/lockers/LifecycleTypes.sol";
import { PlayerStatus } from "@types/registries/PlayerSetTypes.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";
import { TransferLocker } from "@src/lockers/assets/transfer/TransferLocker.sol";

import { LockersTestBase } from "./LockersTestBase.sol";
import { MockFeeRouter } from "./mocks/MockFeeRouter.sol";

contract TransferLockerTest is LockersTestBase {
    address internal hub;

    function setUp() public override {
        super.setUp();
        hub = makeAddr("hub");
        _seedLeagueTopology(LEAGUE, hub);
        _seedPlayerWithFeeRouter(PLAYER, LEAGUE, hub);
    }

    // --------------------------------------------
    //  Init / admin
    // --------------------------------------------

    function test_initialize_setsOwnerAndDeps() public view {
        assertEq(transferLocker.owner(), address(orch));
        assertEq(address(transferLocker.orchestrator()), address(orch));
        assertEq(address(transferLocker.playerSetRegistry()), address(playerSetRegistry));
        assertEq(address(transferLocker.tournamentRegistry()), address(tournamentRegistry));
        assertEq(transferLocker.queueWait(), 24 hours);
    }

    function test_setEligibilityVerifier_once() public {
        _ownerCall(
            address(transferLocker), abi.encodeCall(TransferLocker.setEligibilityVerifier, (eligibilityVerifier))
        );
        assertEq(transferLocker.eligibilityVerifier(), eligibilityVerifier);

        vm.expectRevert(Errors.AlreadySet.selector);
        _ownerCall(
            address(transferLocker), abi.encodeCall(TransferLocker.setEligibilityVerifier, (makeAddr("other")))
        );
    }

    function test_setQueueWait_revertsZero() public {
        vm.expectRevert(Errors.NotConfigured.selector);
        _ownerCall(address(transferLocker), abi.encodeCall(TransferLocker.setQueueWait, (0)));
    }

    // --------------------------------------------
    //  Enqueue / unqueue
    // --------------------------------------------

    function test_enqueue_byOwner() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](1);
        mins[0] = 90;

        _enqueueAsOwner(ids, LifecycleReason.ContinuityUnderThreshold, mins);

        assertTrue(transferLocker.isQueued(PLAYER));
        assertTrue(transferLocker.isQueuedFor(PLAYER, LifecycleReason.ContinuityUnderThreshold));
        assertEq(transferLocker.pendingCount(), 1);

        PendingLifecycle[] memory pending = transferLocker.pendingLifecycle(0, 1);
        assertEq(pending[0].playerId, PLAYER);
        assertEq(uint8(pending[0].reason), uint8(LifecycleReason.ContinuityUnderThreshold));
        assertEq(pending[0].effectiveMins, 90);
        assertEq(uint8(pending[0].status), uint8(LifecycleQueueStatus.Queued));
    }

    function test_enqueue_byEligibilityVerifier() public {
        _ownerCall(
            address(transferLocker), abi.encodeCall(TransferLocker.setEligibilityVerifier, (eligibilityVerifier))
        );

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);

        vm.prank(eligibilityVerifier);
        transferLocker.enqueueLifecycle(ids, LifecycleReason.LeftLeague, mins);
        assertTrue(transferLocker.isQueued(PLAYER));
    }

    function test_enqueue_revertsUnauthorized() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.Unauthorized.selector);
        transferLocker.enqueueLifecycle(ids, LifecycleReason.LeftLeague, mins);
    }

    function test_enqueue_lengthMismatch() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = PLAYER;
        ids[1] = PLAYER_B;
        uint32[] memory mins = new uint32[](1);
        mins[0] = 1;

        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, uint256(2), uint256(1)));
        _enqueueAsOwner(ids, LifecycleReason.LeftLeague, mins);
    }

    function test_enqueue_deactivateAndReactivateIndependent() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);

        _enqueueAsOwner(ids, LifecycleReason.LeftLeague, mins);
        _enqueueAsOwner(ids, LifecycleReason.Reactivate, mins);

        assertTrue(transferLocker.isQueuedFor(PLAYER, LifecycleReason.LeftLeague));
        assertTrue(transferLocker.isQueuedFor(PLAYER, LifecycleReason.Reactivate));
        assertEq(transferLocker.pendingCount(), 2);
    }

    function test_enqueue_skipsDuplicates() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);

        _enqueueAsOwner(ids, LifecycleReason.LeftLeague, mins);
        _enqueueAsOwner(ids, LifecycleReason.LeftLeague, mins);
        assertEq(transferLocker.pendingCount(), 1);
    }

    function test_unqueueAsset() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);
        _enqueueAsOwner(ids, LifecycleReason.LeftLeague, mins);

        _ownerCall(address(transferLocker), abi.encodeCall(TransferLocker.unqueueAsset, (PLAYER)));
        assertFalse(transferLocker.isQueued(PLAYER));
        assertEq(transferLocker.pendingCount(), 0);
    }

    // --------------------------------------------
    //  Process deactivate
    // --------------------------------------------

    function test_processLifecycle_beforeWait_reverts() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);
        _enqueueAsOwner(ids, LifecycleReason.ContinuityUnderThreshold, mins);

        vm.expectRevert(Errors.NothingReady.selector);
        transferLocker.processLifecycle();
    }

    function test_processLifecycle_continuity_setsInactive() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);
        _enqueueAsOwner(ids, LifecycleReason.ContinuityUnderThreshold, mins);

        _warpPastQueueWait();
        bytes32 requestId = transferLocker.processLifecycle();
        assertEq(requestId, bytes32(0));
        assertEq(uint8(playerSetRegistry.lastStatus()), uint8(PlayerStatus.INACTIVE));
        assertEq(playerSetRegistry.lastStatusPlayerId(), PLAYER);
        assertFalse(transferLocker.isQueued(PLAYER));
    }

    function test_processLifecycle_leftLeague_setsInactive() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);
        _enqueueAsOwner(ids, LifecycleReason.LeftLeague, mins);

        _warpPastQueueWait();
        transferLocker.processLifecycle();
        assertEq(uint8(playerSetRegistry.lastStatus()), uint8(PlayerStatus.INACTIVE));
    }

    function test_processLifecycle_rateLimited() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = PLAYER;
        ids[1] = PLAYER_B;
        uint32[] memory mins = new uint32[](0);
        _seedPlayerWithFeeRouter(PLAYER_B, LEAGUE, hub);
        _enqueueAsOwner(ids, LifecycleReason.LeftLeague, mins);

        _warpPastQueueWait();
        transferLocker.processLifecycle();

        vm.expectRevert(abi.encodeWithSelector(RateLimit.RateLimited.selector, block.timestamp + 5 minutes));
        transferLocker.processLifecycle();
    }

    // --------------------------------------------
    //  LeagueTransfer
    // --------------------------------------------

    function test_changedLeague_requestsOracle_andFulfills() public {
        bytes32 newLeague = keccak256("league-2");
        address newHub = makeAddr("hub2");
        _seedLeagueTopology(newLeague, newHub);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);
        _enqueueAsOwner(ids, LifecycleReason.ChangedLeague, mins);

        _warpPastQueueWait();
        bytes32 requestId = transferLocker.processLifecycle();
        assertTrue(requestId != bytes32(0));

        (address consumer, CvmJob job,) = cvmRouter.getPending(requestId);
        assertEq(consumer, address(transferLocker));
        assertEq(uint8(job), uint8(CvmJob.LeagueTransfer));

        bytes32[] memory actives = new bytes32[](1);
        actives[0] = newLeague;
        _fulfillLeagueTransfer(requestId, newLeague, actives);

        assertEq(playerSetRegistry.lastNewLeagueId(), newLeague);
        assertEq(playerSetRegistry.setLeagueIdCount(), 1);
        assertFalse(transferLocker.isQueued(PLAYER));
    }

    function test_reactivate_setsBondingFromHooks() public {
        address feeRouter = playerSetRegistry.getPlayerSet(PLAYER).dopplerData.feeRouter;
        playerSetRegistry.seedPlayer(
            PLAYER, PlayerStatus.INACTIVE, LEAGUE, feeRouter, hookDoppler, hookMigrator, hookDoppler
        );

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);
        _enqueueAsOwner(ids, LifecycleReason.Reactivate, mins);

        _warpPastQueueWait();
        bytes32 requestId = transferLocker.processLifecycle();

        bytes32[] memory actives = new bytes32[](1);
        actives[0] = LEAGUE;
        _fulfillLeagueTransfer(requestId, LEAGUE, actives);

        assertEq(uint8(playerSetRegistry.lastStatus()), uint8(PlayerStatus.BONDING));
        assertEq(playerSetRegistry.setLeagueIdCount(), 1);
    }

    function test_leagueTransfer_errRearms() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);
        _enqueueAsOwner(ids, LifecycleReason.ChangedLeague, mins);

        _warpPastQueueWait();
        bytes32 requestId = transferLocker.processLifecycle();

        cvmRouter.fulfill(requestId, "", bytes("fail"));

        assertTrue(transferLocker.isQueued(PLAYER));
        PendingLifecycle[] memory pending = transferLocker.pendingLifecycle(0, 1);
        assertEq(uint8(pending[0].status), uint8(LifecycleQueueStatus.Queued));
    }

    function test_leagueTransfer_invalidPayloadRearms() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);
        _enqueueAsOwner(ids, LifecycleReason.ChangedLeague, mins);

        _warpPastQueueWait();
        bytes32 requestId = transferLocker.processLifecycle();

        // Missing hub / not linked → validation fails → rearm
        bytes32 badLeague = keccak256("unknown-league");
        bytes32[] memory actives = new bytes32[](1);
        actives[0] = badLeague;
        _fulfillLeagueTransfer(requestId, badLeague, actives);

        assertTrue(transferLocker.isQueued(PLAYER));
        assertEq(playerSetRegistry.setLeagueIdCount(), 0);
    }

    // --------------------------------------------
    //  Fee topology
    // --------------------------------------------

    function test_requireFeeTopologyConsistent() public view {
        transferLocker.requireFeeTopologyConsistent(PLAYER);
    }

    function test_requireFeeTopologyConsistent_mismatch() public {
        MockFeeRouter feeRouter = MockFeeRouter(payable(playerSetRegistry.getPlayerSet(PLAYER).dopplerData.feeRouter));
        feeRouter.setPbrFeeHub(makeAddr("wrong-hub"));

        vm.expectRevert();
        transferLocker.requireFeeTopologyConsistent(PLAYER);
    }
}
