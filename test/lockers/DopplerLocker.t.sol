// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DeploymentsErrors as Errors } from "@errors/lockers/DeploymentsErrors.sol";
import { RateLimit } from "@base/abstract/RateLimit.sol";
import { DopplerLocker } from "@src/lockers/assets/deploy/DopplerLocker.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";

import { LockersTestBase } from "./LockersTestBase.sol";

contract DopplerLockerTest is LockersTestBase {
    function setUp() public override {
        super.setUp();
        address hub = makeAddr("league-hub");
        tournamentRegistry.setTournamentExists(LEAGUE, true);
        tournamentRegistry.setPbrFeeHub(LEAGUE, hub);
        tournamentRegistry.setSeasonTournament(SEASON, LEAGUE);
    }

    function test_constructor_setsQueuePolicy() public view {
        assertEq(dopplerLocker.queueWait(), 24 hours);
        assertEq(dopplerLocker.retryWait(), 5 minutes);
        assertEq(dopplerLocker.maxDeployAttempts(), 5);
    }

    function test_queueAssets_revertsZeroId() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        vm.expectRevert(Errors.ZeroId.selector);
        _ownerCall(address(dopplerLocker), abi.encodeCall(DopplerLocker.queueAssets, (bytes32(0), SEASON, ids)));
    }

    function test_queueAssets_revertsHubMissing() public {
        tournamentRegistry.setPbrFeeHub(LEAGUE, address(0));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        vm.expectRevert(abi.encodeWithSelector(Errors.HubNotRegistered.selector, LEAGUE));
        _ownerCall(address(dopplerLocker), abi.encodeCall(DopplerLocker.queueAssets, (LEAGUE, SEASON, ids)));
    }

    function test_queueAssets_revertsSeasonMismatch() public {
        tournamentRegistry.setSeasonTournament(SEASON, keccak256("other-league"));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        vm.expectRevert(abi.encodeWithSelector(Errors.LeagueMismatch.selector, LEAGUE, keccak256("other-league")));
        _ownerCall(address(dopplerLocker), abi.encodeCall(DopplerLocker.queueAssets, (LEAGUE, SEASON, ids)));
    }

    function test_queueAssets_revertsTooMany() public {
        bytes32[] memory ids = new bytes32[](51);
        for (uint256 i; i < 51; ++i) {
            ids[i] = keccak256(abi.encode(i));
        }
        vm.expectRevert(abi.encodeWithSelector(Errors.TooManyPlayers.selector, uint256(50)));
        _ownerCall(address(dopplerLocker), abi.encodeCall(DopplerLocker.queueAssets, (LEAGUE, SEASON, ids)));
    }

    function test_queueAssets_intake_requestsMetadata() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        _ownerCall(address(dopplerLocker), abi.encodeCall(DopplerLocker.queueAssets, (LEAGUE, SEASON, ids)));

        assertEq(dopplerLocker.queueCount(), 1);
        assertTrue(dopplerLocker.isQueued(PLAYER));

        bytes32 requestId = cvmRouter.lastRequestId();
        (address consumer, CvmJob job, bytes memory args) = cvmRouter.getPending(requestId);
        assertEq(consumer, address(dopplerLocker));
        assertEq(uint8(job), uint8(CvmJob.PlayerMetadata));

        (bytes32 seasonId, bytes32[] memory page) = abi.decode(args, (bytes32, bytes32[]));
        assertEq(seasonId, SEASON);
        assertEq(page.length, 1);
        assertEq(page[0], PLAYER);

        DopplerLocker.QueueEntry memory e = dopplerLocker.queueEntry(PLAYER);
        assertEq(uint8(e.status), uint8(DopplerLocker.QueueStatus.AwaitingMetadata));
    }

    function test_metadataFulfill_readyToQueue_thenPromote() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = PLAYER;
        _ownerCall(address(dopplerLocker), abi.encodeCall(DopplerLocker.queueAssets, (LEAGUE, SEASON, ids)));

        bytes32 requestId = cvmRouter.lastRequestId();
        string[] memory names = new string[](1);
        names[0] = "Player One";
        string[] memory symbols = new string[](1);
        symbols[0] = "P1";
        cvmRouter.fulfill(requestId, abi.encode(SEASON, ids, names, symbols), "");

        DopplerLocker.QueueEntry memory e = dopplerLocker.queueEntry(PLAYER);
        assertEq(e.name, "Player One");
        assertEq(e.symbol, "P1");
        assertEq(uint8(e.status), uint8(DopplerLocker.QueueStatus.ReadyToQueue));

        _ownerCall(
            address(dopplerLocker), abi.encodeCall(DopplerLocker.queueAssets, (LEAGUE, SEASON, new bytes32[](0)))
        );
        e = dopplerLocker.queueEntry(PLAYER);
        assertEq(uint8(e.status), uint8(DopplerLocker.QueueStatus.Queued));
    }

    function test_editMetadata_onlyQueued() public {
        _queueThroughQueued(PLAYER);

        _ownerCall(address(dopplerLocker), abi.encodeCall(DopplerLocker.editMetadata, (PLAYER, "New Name", "NN")));
        DopplerLocker.QueueEntry memory e = dopplerLocker.queueEntry(PLAYER);
        assertEq(e.name, "New Name");
        assertEq(e.symbol, "NN");
    }

    function test_unqueueAsset_fromQueued() public {
        _queueThroughQueued(PLAYER);
        _ownerCall(address(dopplerLocker), abi.encodeCall(DopplerLocker.unqueueAsset, (PLAYER)));
        assertFalse(dopplerLocker.isQueued(PLAYER));
        assertEq(dopplerLocker.queueCount(), 0);
    }

    function test_deployAssets_nothingReady() public {
        vm.expectRevert(Errors.NothingReady.selector);
        dopplerLocker.deployAssets();
    }

    function test_deployAssets_requestsFinalConfig_afterWait() public {
        _queueThroughQueued(PLAYER);
        vm.warp(block.timestamp + dopplerLocker.queueWait() + 1);

        bytes32 requestId = dopplerLocker.deployAssets();
        assertTrue(requestId != bytes32(0));

        (, CvmJob job,) = cvmRouter.getPending(requestId);
        assertEq(uint8(job), uint8(CvmJob.FinalConfig));

        DopplerLocker.QueueEntry memory e = dopplerLocker.queueEntry(PLAYER);
        assertEq(uint8(e.status), uint8(DopplerLocker.QueueStatus.AwaitingFinalConfig));
    }

    function test_finalConfig_err_requeues() public {
        _queueThroughQueued(PLAYER);
        vm.warp(block.timestamp + dopplerLocker.queueWait() + 1);
        bytes32 requestId = dopplerLocker.deployAssets();

        cvmRouter.fulfill(requestId, "", bytes("oracle-fail"));

        DopplerLocker.QueueEntry memory e = dopplerLocker.queueEntry(PLAYER);
        assertEq(uint8(e.status), uint8(DopplerLocker.QueueStatus.Queued));
    }

    function test_finalConfig_badPayload_requeues() public {
        _queueThroughQueued(PLAYER);
        vm.warp(block.timestamp + dopplerLocker.queueWait() + 1);
        bytes32 requestId = dopplerLocker.deployAssets();

        bytes memory bad = abi.encode(bytes32(0), address(0), bytes32(0), address(0), "");
        cvmRouter.fulfill(requestId, bad, "");

        DopplerLocker.QueueEntry memory e = dopplerLocker.queueEntry(PLAYER);
        assertEq(uint8(e.status), uint8(DopplerLocker.QueueStatus.Queued));
    }

    function test_applyFinalConfig_revertsExternalCaller() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        dopplerLocker.applyFinalConfig(PLAYER, bytes(""));
    }

    function test_executeDeploy_revertsExternalCaller() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        dopplerLocker.executeDeploy(PLAYER);
    }

    function test_resetFailedDeploy_afterExhaustion() public {
        _timelockCall(address(dopplerLocker), abi.encodeCall(DopplerLocker.setMaxDeployAttempts, (1)));

        _queueThroughQueued(PLAYER);
        vm.warp(block.timestamp + dopplerLocker.queueWait() + 1);
        bytes32 requestId = dopplerLocker.deployAssets();
        cvmRouter.fulfill(requestId, "", bytes("fail"));

        DopplerLocker.QueueEntry memory e = dopplerLocker.queueEntry(PLAYER);
        assertEq(uint8(e.status), uint8(DopplerLocker.QueueStatus.DeployFailed));

        _timelockCall(address(dopplerLocker), abi.encodeCall(DopplerLocker.resetFailedDeploy, (PLAYER, false)));
        e = dopplerLocker.queueEntry(PLAYER);
        assertEq(uint8(e.status), uint8(DopplerLocker.QueueStatus.Queued));
    }

    function test_deployAssets_rateLimited() public {
        _queueThroughQueued(PLAYER);
        _queueThroughQueued(PLAYER_B);
        vm.warp(block.timestamp + dopplerLocker.queueWait() + 1);

        dopplerLocker.deployAssets();
        vm.expectRevert(abi.encodeWithSelector(RateLimit.RateLimited.selector, block.timestamp + 5 minutes));
        dopplerLocker.deployAssets();
    }

    function _queueThroughQueued(bytes32 playerId) internal {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = playerId;
        _ownerCall(address(dopplerLocker), abi.encodeCall(DopplerLocker.queueAssets, (LEAGUE, SEASON, ids)));

        bytes32 requestId = cvmRouter.lastRequestId();
        string[] memory names = new string[](1);
        names[0] = "Player";
        string[] memory symbols = new string[](1);
        symbols[0] = "PLY";
        cvmRouter.fulfill(requestId, abi.encode(SEASON, ids, names, symbols), "");

        _ownerCall(
            address(dopplerLocker), abi.encodeCall(DopplerLocker.queueAssets, (LEAGUE, SEASON, new bytes32[](0)))
        );
    }
}
