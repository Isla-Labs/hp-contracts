// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RateLimit } from "@base/abstract/RateLimit.sol";
import { LifecycleErrors as Errors } from "@errors/initializers/LifecycleErrors.sol";
import { LifecycleManager } from "@src/initializers/lifecycle/LifecycleManager.sol";
import { LifecycleQueueStatus, LifecycleReason, PendingLifecycle } from "@types/initializers/LifecycleTypes.sol";
import { PlayerStatus } from "@types/registries/PlayerSetTypes.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";

import { InitializersTestBase } from "./InitializersTestBase.sol";
import { MockFeeRouter } from "./mocks/MockFeeRouter.sol";

contract LifecycleManagerTest is InitializersTestBase {
    address internal hub;

    function setUp() public override {
        super.setUp();
        hub = makeAddr("hub");
        _seedLeagueTopology(LEAGUE, hub);
        _seedPlayerWithFeeRouter(PLAYER, LEAGUE, hub);
    }

    function test_constructor_setsQueueWait() public view {
        assertEq(lifecycleManager.queueWait(), 24 hours);
    }

    function test_setQueueWait_revertsZero() public {
        vm.expectRevert(Errors.NotConfigured.selector);
        _timelockCall(address(lifecycleManager), abi.encodeCall(LifecycleManager.setQueueWait, (0)));
    }

    function test_queueChanges_byOrchestrator() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](1);
        mins[0] = 90;

        _queueLifecycle(ids, LifecycleReason.ContinuityUnderThreshold, mins);

        assertTrue(lifecycleManager.isQueued(PLAYER));
        assertTrue(lifecycleManager.isQueuedFor(PLAYER, LifecycleReason.ContinuityUnderThreshold));
        assertEq(lifecycleManager.pendingCount(), 1);

        PendingLifecycle[] memory pending = lifecycleManager.pendingLifecycle(0, 1);
        assertEq(pending[0].playerId, PLAYER);
        assertEq(uint8(pending[0].reason), uint8(LifecycleReason.ContinuityUnderThreshold));
        assertEq(pending[0].effectiveMins, 90);
        assertEq(uint8(pending[0].status), uint8(LifecycleQueueStatus.Queued));
    }

    function test_queueChanges_byEligibilityVerifier() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);

        vm.prank(eligibilityVerifier);
        orch.queueChanges(ids, LifecycleReason.LeftLeague, mins);
        assertTrue(lifecycleManager.isQueued(PLAYER));
    }

    function test_queueChanges_revertsUnauthorized() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.Unauthorized.selector);
        orch.queueChanges(ids, LifecycleReason.LeftLeague, mins);
    }

    function test_queueChanges_lengthMismatch() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = PLAYER;
        ids[1] = PLAYER_B;
        uint32[] memory mins = new uint32[](1);
        mins[0] = 1;

        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, uint256(2), uint256(1)));
        _queueLifecycle(ids, LifecycleReason.LeftLeague, mins);
    }

    function test_queueChanges_deactivateAndReactivateIndependent() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);

        _queueLifecycle(ids, LifecycleReason.LeftLeague, mins);
        _queueLifecycle(ids, LifecycleReason.Reactivate, mins);

        assertTrue(lifecycleManager.isQueuedFor(PLAYER, LifecycleReason.LeftLeague));
        assertTrue(lifecycleManager.isQueuedFor(PLAYER, LifecycleReason.Reactivate));
        assertEq(lifecycleManager.pendingCount(), 2);
    }

    function test_queueChanges_skipsDuplicates() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);

        _queueLifecycle(ids, LifecycleReason.LeftLeague, mins);
        _queueLifecycle(ids, LifecycleReason.LeftLeague, mins);
        assertEq(lifecycleManager.pendingCount(), 1);
    }

    function test_unqueueAsset() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);
        _queueLifecycle(ids, LifecycleReason.LeftLeague, mins);

        _asOrch(address(lifecycleManager), abi.encodeCall(LifecycleManager.unqueueAsset, (PLAYER)));
        assertFalse(lifecycleManager.isQueued(PLAYER));
        assertEq(lifecycleManager.pendingCount(), 0);
    }

    function test_processLifecycle_beforeWait_reverts() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);
        _queueLifecycle(ids, LifecycleReason.ContinuityUnderThreshold, mins);

        vm.expectRevert(Errors.NothingReady.selector);
        _processLifecycle();
    }

    function test_processLifecycle_continuity_setsInactive() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);
        _queueLifecycle(ids, LifecycleReason.ContinuityUnderThreshold, mins);

        _warpPastQueueWait();
        bytes32 requestId = _processLifecycle();
        assertEq(requestId, bytes32(0));
        assertEq(uint8(playerSetRegistry.lastStatus()), uint8(PlayerStatus.INACTIVE));
        assertEq(playerSetRegistry.lastStatusPlayerId(), PLAYER);
        assertFalse(lifecycleManager.isQueued(PLAYER));
    }

    function test_processLifecycle_leftLeague_setsInactive() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);
        _queueLifecycle(ids, LifecycleReason.LeftLeague, mins);

        _warpPastQueueWait();
        _processLifecycle();
        assertEq(uint8(playerSetRegistry.lastStatus()), uint8(PlayerStatus.INACTIVE));
    }

    function test_processLifecycle_rateLimited() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = PLAYER;
        ids[1] = PLAYER_B;
        uint32[] memory mins = new uint32[](0);
        _seedPlayerWithFeeRouter(PLAYER_B, LEAGUE, hub);
        _queueLifecycle(ids, LifecycleReason.LeftLeague, mins);

        _warpPastQueueWait();
        _processLifecycle();

        vm.expectRevert(abi.encodeWithSelector(RateLimit.RateLimited.selector, block.timestamp + DEPLOY_COOLDOWN));
        _processLifecycle();
    }

    function test_changedLeague_requestsOracle_andFulfills() public {
        bytes32 newLeague = keccak256("league-2");
        address newHub = makeAddr("hub2");
        _seedLeagueTopology(newLeague, newHub);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);
        _queueLifecycle(ids, LifecycleReason.ChangedLeague, mins);

        _warpPastQueueWait();
        bytes32 requestId = _processLifecycle();
        assertTrue(requestId != bytes32(0));

        (address consumer, CvmJob job,) = cvmRouter.getPending(requestId);
        assertEq(consumer, address(lifecycleManager));
        assertEq(uint8(job), uint8(CvmJob.LeagueTransfer));

        bytes32[] memory actives = new bytes32[](1);
        actives[0] = newLeague;
        _fulfillLeagueTransfer(requestId, newLeague, actives);

        assertEq(playerSetRegistry.lastNewLeagueId(), newLeague);
        assertEq(playerSetRegistry.setLeagueIdCount(), 1);
        assertFalse(lifecycleManager.isQueued(PLAYER));
    }

    function test_reactivate_setsBondingFromHooks() public {
        address feeRouter = playerSetRegistry.getPlayerSet(PLAYER).dopplerData.feeRouter;
        playerSetRegistry.seedPlayer(
            PLAYER, PlayerStatus.INACTIVE, LEAGUE, feeRouter, hookDoppler, hookMigrator, hookDoppler
        );

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);
        _queueLifecycle(ids, LifecycleReason.Reactivate, mins);

        _warpPastQueueWait();
        bytes32 requestId = _processLifecycle();

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
        _queueLifecycle(ids, LifecycleReason.ChangedLeague, mins);

        _warpPastQueueWait();
        bytes32 requestId = _processLifecycle();

        cvmRouter.fulfill(requestId, "", bytes("fail"));

        assertTrue(lifecycleManager.isQueued(PLAYER));
        PendingLifecycle[] memory pending = lifecycleManager.pendingLifecycle(0, 1);
        assertEq(uint8(pending[0].status), uint8(LifecycleQueueStatus.Queued));
    }

    function test_leagueTransfer_invalidPayloadRearms() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        uint32[] memory mins = new uint32[](0);
        _queueLifecycle(ids, LifecycleReason.ChangedLeague, mins);

        _warpPastQueueWait();
        bytes32 requestId = _processLifecycle();

        bytes32 badLeague = keccak256("unknown-league");
        bytes32[] memory actives = new bytes32[](1);
        actives[0] = badLeague;
        _fulfillLeagueTransfer(requestId, badLeague, actives);

        assertTrue(lifecycleManager.isQueued(PLAYER));
        assertEq(playerSetRegistry.setLeagueIdCount(), 0);
    }

    function test_requireFeeTopologyConsistent() public view {
        lifecycleManager.requireFeeTopologyConsistent(PLAYER);
    }

    function test_requireFeeTopologyConsistent_mismatch() public {
        MockFeeRouter feeRouter = MockFeeRouter(payable(playerSetRegistry.getPlayerSet(PLAYER).dopplerData.feeRouter));
        feeRouter.setPbrFeeHub(makeAddr("wrong-hub"));

        vm.expectRevert();
        lifecycleManager.requireFeeTopologyConsistent(PLAYER);
    }
}
