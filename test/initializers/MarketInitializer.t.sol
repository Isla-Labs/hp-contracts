// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RateLimit } from "@base/abstract/RateLimit.sol";
import { DeploymentsErrors as Errors } from "@errors/initializers/DeploymentsErrors.sol";
import { MarketInitializer } from "@src/initializers/markets/MarketInitializer.sol";
import { MarketQueueEntry, MarketQueueStatus } from "@types/initializers/MarketInitializerTypes.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";

import { InitializersTestBase } from "./InitializersTestBase.sol";

contract MarketInitializerTest is InitializersTestBase {
    function setUp() public override {
        super.setUp();
        address hub = makeAddr("league-hub");
        tournamentRegistry.setTournamentExists(LEAGUE, true);
        tournamentRegistry.setPbrFeeHub(LEAGUE, hub);
        tournamentRegistry.setSeasonTournament(SEASON, LEAGUE);
    }

    function test_constructor_setsQueuePolicy() public view {
        assertEq(marketInitializer.queueWait(), 24 hours);
        assertEq(marketInitializer.retryWait(), 5 minutes);
        assertEq(marketInitializer.maxDeployAttempts(), 5);
    }

    function test_queueAssets_revertsZeroId() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        vm.expectRevert(Errors.ZeroId.selector);
        orch.queueAssets(bytes32(0), SEASON, ids);
    }

    function test_queueAssets_revertsHubMissing() public {
        tournamentRegistry.setPbrFeeHub(LEAGUE, address(0));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        vm.expectRevert(abi.encodeWithSelector(Errors.HubNotRegistered.selector, LEAGUE));
        orch.queueAssets(LEAGUE, SEASON, ids);
    }

    function test_queueAssets_revertsSeasonMismatch() public {
        tournamentRegistry.setSeasonTournament(SEASON, keccak256("other-league"));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        vm.expectRevert(abi.encodeWithSelector(Errors.LeagueMismatch.selector, LEAGUE, keccak256("other-league")));
        orch.queueAssets(LEAGUE, SEASON, ids);
    }

    function test_queueAssets_revertsTooMany() public {
        bytes32[] memory ids = new bytes32[](51);
        for (uint256 i; i < 51; ++i) {
            ids[i] = keccak256(abi.encode(i));
        }
        vm.expectRevert(abi.encodeWithSelector(Errors.TooManyPlayers.selector, uint256(50)));
        orch.queueAssets(LEAGUE, SEASON, ids);
    }

    function test_queueAssets_intake_requestsMetadata() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        orch.queueAssets(LEAGUE, SEASON, ids);

        assertEq(marketInitializer.queueCount(), 1);
        assertTrue(marketInitializer.isQueued(PLAYER));

        bytes32 requestId = cvmRouter.lastRequestId();
        (address consumer, CvmJob job, bytes memory args) = cvmRouter.getPending(requestId);
        assertEq(consumer, address(marketInitializer));
        assertEq(uint8(job), uint8(CvmJob.PlayerMetadata));

        (bytes32 seasonId, bytes32[] memory page) = abi.decode(args, (bytes32, bytes32[]));
        assertEq(seasonId, SEASON);
        assertEq(page.length, 1);
        assertEq(page[0], PLAYER);

        MarketQueueEntry memory e = marketInitializer.queueEntry(PLAYER);
        assertEq(uint8(e.status), uint8(MarketQueueStatus.AwaitingMetadata));
    }

    function test_metadataFulfill_setsQueued() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        orch.queueAssets(LEAGUE, SEASON, ids);

        _fulfillMetadata(cvmRouter.lastRequestId(), SEASON, ids, "Player One", "P1");

        MarketQueueEntry memory e = marketInitializer.queueEntry(PLAYER);
        assertEq(e.name, "Player One");
        assertEq(e.symbol, "P1");
        assertTrue(e.metadataSet);
        assertEq(uint8(e.status), uint8(MarketQueueStatus.Queued));
    }

    function test_editMetadata_onlyQueued() public {
        _queueThroughQueued(PLAYER);

        marketInitializer.editMetadata(PLAYER, "New Name", "NN");
        MarketQueueEntry memory e = marketInitializer.queueEntry(PLAYER);
        assertEq(e.name, "New Name");
        assertEq(e.symbol, "NN");
    }

    function test_unqueueAsset_fromQueued() public {
        _queueThroughQueued(PLAYER);
        marketInitializer.unqueueAsset(PLAYER);
        assertFalse(marketInitializer.isQueued(PLAYER));
        assertEq(marketInitializer.queueCount(), 0);
    }

    function test_deployAssets_nothingReady() public {
        vm.expectRevert(Errors.NothingReady.selector);
        _processQueue();
    }

    function test_deployAssets_requestsFinalConfig_afterWait() public {
        _queueThroughQueued(PLAYER);
        _warpPastMarketQueueWait();

        bytes32 requestId = _processQueue();
        assertTrue(requestId != bytes32(0));

        (, CvmJob job,) = cvmRouter.getPending(requestId);
        assertEq(uint8(job), uint8(CvmJob.FinalConfig));

        MarketQueueEntry memory e = marketInitializer.queueEntry(PLAYER);
        assertEq(uint8(e.status), uint8(MarketQueueStatus.AwaitingFinalConfig));
    }

    function test_finalConfig_err_requeues() public {
        _queueThroughQueued(PLAYER);
        _warpPastMarketQueueWait();
        bytes32 requestId = _processQueue();

        cvmRouter.fulfill(requestId, "", bytes("oracle-fail"));

        MarketQueueEntry memory e = marketInitializer.queueEntry(PLAYER);
        assertEq(uint8(e.status), uint8(MarketQueueStatus.Queued));
    }

    function test_finalConfig_badPayload_requeues() public {
        _queueThroughQueued(PLAYER);
        _warpPastMarketQueueWait();
        bytes32 requestId = _processQueue();

        bytes memory bad = abi.encode(bytes32(0), address(0), bytes32(0), address(0), "", "");
        cvmRouter.fulfill(requestId, bad, "");

        MarketQueueEntry memory e = marketInitializer.queueEntry(PLAYER);
        assertEq(uint8(e.status), uint8(MarketQueueStatus.Queued));
    }

    function test_applyFinalConfig_revertsExternalCaller() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        marketInitializer.applyFinalConfig(PLAYER, bytes(""));
    }

    function test_executeDeploy_revertsExternalCaller() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        marketInitializer.executeDeploy(PLAYER);
    }

    function test_resetFailedDeploy_afterExhaustion() public {
        _timelockCall(address(marketInitializer), abi.encodeCall(MarketInitializer.setMaxDeployAttempts, (1)));

        _queueThroughQueued(PLAYER);
        _warpPastMarketQueueWait();
        bytes32 requestId = _processQueue();
        cvmRouter.fulfill(requestId, "", bytes("fail"));

        MarketQueueEntry memory e = marketInitializer.queueEntry(PLAYER);
        assertEq(uint8(e.status), uint8(MarketQueueStatus.DeployFailed));

        marketInitializer.resetFailedDeploy(PLAYER, false);
        e = marketInitializer.queueEntry(PLAYER);
        assertEq(uint8(e.status), uint8(MarketQueueStatus.Queued));
    }

    function test_processQueue_rateLimited() public {
        _queueThroughQueued(PLAYER);
        _queueThroughQueued(PLAYER_B);
        _warpPastMarketQueueWait();

        _processQueue();
        vm.expectRevert(abi.encodeWithSelector(RateLimit.RateLimited.selector, block.timestamp + DEPLOY_COOLDOWN));
        _processQueue();
    }

    function test_queueAssets_revertsUnauthorized() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.Unauthorized.selector);
        orch.queueAssets(LEAGUE, SEASON, ids);
    }
}
