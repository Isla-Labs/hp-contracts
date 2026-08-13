// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PbrSettleErrors as Errors } from "@errors/data/PbrSettleErrors.sol";
import { PbrSettleEvents as Events } from "@events/data/PbrSettleEvents.sol";
import { FixturePhase, FixtureSettlement, RoundSettlePhase, RoundSettlement } from "@types/data/PbrSettleTypes.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";

import { PbrSettleTestBase } from "./PbrSettleTestBase.sol";

contract PbrSettleTest is PbrSettleTestBase {
    // --------------------------------------------
    //  settleRound — auth / validation
    // --------------------------------------------

    function test_settleRound_revertsUnauthorized() public {
        _setFixtures(_oneFixture(FIXTURE_1));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.Unauthorized.selector);
        pbrSettle.settleRound(TOURNAMENT, YEAR, ROUND, UTILIZED);
    }

    function test_settleRound_revertsTreasuryMissing() public {
        tournamentRegistry.setPbrTreasury(TOURNAMENT, address(0));
        _setFixtures(_oneFixture(FIXTURE_1));
        vm.prank(makeAddr("anyone"));
        vm.expectRevert(abi.encodeWithSelector(Errors.TreasuryMissing.selector, TOURNAMENT));
        pbrSettle.settleRound(TOURNAMENT, YEAR, ROUND, UTILIZED);
    }

    function test_settleRound_revertsZeroUtilizedHash() public {
        _setFixtures(_oneFixture(FIXTURE_1));
        vm.prank(address(treasury));
        vm.expectRevert(Errors.ZeroHash.selector);
        pbrSettle.settleRound(TOURNAMENT, YEAR, ROUND, bytes32(0));
    }

    function test_settleRound_revertsNoFixtures() public {
        _setFixtures(new bytes32[](0));
        vm.prank(address(treasury));
        vm.expectRevert(Errors.NoFixtures.selector);
        pbrSettle.settleRound(TOURNAMENT, YEAR, ROUND, UTILIZED);
    }

    function test_settleRound_revertsZeroFixture() public {
        _setFixtures(_oneFixture(bytes32(0)));
        vm.prank(address(treasury));
        vm.expectRevert(Errors.ZeroFixture.selector);
        pbrSettle.settleRound(TOURNAMENT, YEAR, ROUND, UTILIZED);
    }

    function test_settleRound_revertsWhilePending() public {
        _settleSimple();
        bytes32 rid = pbrSettle.roundId(TOURNAMENT, YEAR, ROUND);
        vm.prank(address(treasury));
        vm.expectRevert(abi.encodeWithSelector(Errors.RoundSettlePending.selector, rid));
        pbrSettle.settleRound(TOURNAMENT, YEAR, ROUND, UTILIZED);
    }

    function test_settleRound_fansOutSettleDms() public {
        _setFixtures(_twoFixtures(FIXTURE_1, FIXTURE_2));

        vm.expectEmit(true, true, false, true);
        emit Events.RoundSettleOpened(TOURNAMENT, address(treasury), YEAR, ROUND, UTILIZED, 2);

        bytes32[] memory ids = _settleAsTreasury(UTILIZED);
        assertEq(ids.length, 2);
        assertEq(cvmRouter.requestCount(), 2);

        RoundSettlement memory round = pbrSettle.getRoundSettlement(TOURNAMENT, YEAR, ROUND);
        assertEq(uint8(round.phase), uint8(RoundSettlePhase.Requested));
        assertEq(round.treasury, address(treasury));
        assertEq(round.utilizedHash, UTILIZED);
        assertEq(round.fixturesExpected, 2);
        assertEq(round.fixturesSettled, 0);

        for (uint256 i; i < 2; ++i) {
            (address consumer, CvmJob job, bytes memory args) = cvmRouter.getPending(ids[i]);
            assertEq(consumer, address(pbrSettle));
            assertEq(uint8(job), uint8(CvmJob.SettleDms));
            (bytes32 tournamentId, uint16 year, uint32 roundNumber, bytes32 fixtureId, bytes32 utilizedHash) =
                abi.decode(args, (bytes32, uint16, uint32, bytes32, bytes32));
            assertEq(tournamentId, TOURNAMENT);
            assertEq(year, YEAR);
            assertEq(roundNumber, ROUND);
            assertEq(utilizedHash, UTILIZED);
            assertTrue(fixtureId == FIXTURE_1 || fixtureId == FIXTURE_2);
        }
    }

    // --------------------------------------------
    //  Fulfill — happy path / validation
    // --------------------------------------------

    function test_fulfill_appliesAndCompletes() public {
        bytes32 requestId = _settleSimple();
        bytes32 digest = keccak256("digest-1");

        _fulfillOk(requestId, UTILIZED, digest);

        FixtureSettlement memory f = pbrSettle.getFixtureSettlement(TOURNAMENT, YEAR, ROUND, FIXTURE_1);
        assertEq(uint8(f.phase), uint8(FixturePhase.Proven));
        assertEq(f.fixtureDigest, digest);
        assertEq(f.proofHash, keccak256(bytes("proof")));
        assertEq(f.retryCount, 0);

        assertEq(treasury.applyCount(), 1);
        assertEq(treasury.lastFixtureId(), FIXTURE_1);
        assertEq(treasury.lastFixtureDigest(), digest);
        assertEq(treasury.lastVaults().length, 2);
        assertEq(treasury.lastMwPoints()[1], 20);

        RoundSettlement memory round = pbrSettle.getRoundSettlement(TOURNAMENT, YEAR, ROUND);
        assertEq(uint8(round.phase), uint8(RoundSettlePhase.Complete));
        assertEq(round.fixturesSettled, 1);
    }

    function test_fulfill_treasuryDoneShortCircuitsRound() public {
        _setFixtures(_twoFixtures(FIXTURE_1, FIXTURE_2));
        treasury.setNextDone(true);
        bytes32[] memory ids = _settleAsTreasury(UTILIZED);

        bytes32 fixture0 = _fixtureFromRequest(ids[0]);
        _fulfillOk(ids[0], UTILIZED, keccak256("d0"));

        RoundSettlement memory round = pbrSettle.getRoundSettlement(TOURNAMENT, YEAR, ROUND);
        assertEq(uint8(round.phase), uint8(RoundSettlePhase.Complete));
        assertEq(round.fixturesSettled, 1);
        // Second fixture still Requested in-flight.
        FixtureSettlement memory f1 = pbrSettle.getFixtureSettlement(TOURNAMENT, YEAR, ROUND, fixture0);
        assertEq(uint8(f1.phase), uint8(FixturePhase.Proven));
    }

    function test_fulfill_multiFixtureCompletesOnCounter() public {
        _setFixtures(_twoFixtures(FIXTURE_1, FIXTURE_2));
        bytes32[] memory ids = _settleAsTreasury(UTILIZED);

        bytes32 f0 = _fixtureFromRequest(ids[0]);
        bytes32 f1 = _fixtureFromRequest(ids[1]);

        _fulfillOk(ids[0], UTILIZED, keccak256("d0"));
        assertEq(uint8(pbrSettle.getRoundSettlement(TOURNAMENT, YEAR, ROUND).phase), uint8(RoundSettlePhase.Requested));
        assertEq(pbrSettle.getRoundSettlement(TOURNAMENT, YEAR, ROUND).fixturesSettled, 1);

        _fulfillOk(ids[1], UTILIZED, keccak256("d1"));
        assertEq(uint8(pbrSettle.getRoundSettlement(TOURNAMENT, YEAR, ROUND).phase), uint8(RoundSettlePhase.Complete));
        assertEq(pbrSettle.getRoundSettlement(TOURNAMENT, YEAR, ROUND).fixturesSettled, 2);
        assertEq(uint8(pbrSettle.getFixtureSettlement(TOURNAMENT, YEAR, ROUND, f0).phase), uint8(FixturePhase.Proven));
        assertEq(uint8(pbrSettle.getFixtureSettlement(TOURNAMENT, YEAR, ROUND, f1).phase), uint8(FixturePhase.Proven));
    }

    function test_fulfill_revertsUtilizedHashMismatch() public {
        bytes32 requestId = _settleSimple();
        address[] memory vaults = new address[](0);
        uint256[] memory points = new uint256[](0);

        vm.expectRevert(abi.encodeWithSelector(Errors.UtilizedHashMismatch.selector, UTILIZED, keccak256("wrong")));
        cvmRouter.fulfill(requestId, _encodeOk(keccak256("wrong"), keccak256("d"), vaults, points), "");
    }

    function test_fulfill_revertsZeroDigest() public {
        bytes32 requestId = _settleSimple();
        address[] memory vaults = new address[](0);
        uint256[] memory points = new uint256[](0);

        vm.expectRevert(Errors.ZeroHash.selector);
        cvmRouter.fulfill(requestId, _encodeOk(UTILIZED, bytes32(0), vaults, points), "");
    }

    function test_fulfill_revertsLengthMismatch() public {
        bytes32 requestId = _settleSimple();
        address[] memory vaults = new address[](1);
        vaults[0] = vaultA;
        uint256[] memory points = new uint256[](2);
        points[0] = 1;
        points[1] = 2;

        vm.expectRevert(Errors.LengthMismatch.selector);
        cvmRouter.fulfill(requestId, _encodeOk(UTILIZED, keccak256("d"), vaults, points), "");
    }

    function test_unknownOracleRequest_reverts() public {
        bytes32 fake = keccak256("unknown");
        vm.prank(address(cvmRouter));
        vm.expectRevert(abi.encodeWithSelector(Errors.UnknownOracleRequest.selector, fake));
        pbrSettle.handleOracleFulfillment(fake, "", "");
    }

    // --------------------------------------------
    //  Auto-retry / exhaust / manual retry
    // --------------------------------------------

    function test_fulfillErr_autoRetriesUpToMax() public {
        bytes32 requestId = _settleSimple();

        // Fail 1 → retryCount 1
        _fulfillErr(requestId, bytes("fail-1"));
        assertEq(pbrSettle.getFixtureSettlement(TOURNAMENT, YEAR, ROUND, FIXTURE_1).retryCount, 1);
        assertEq(
            uint8(pbrSettle.getFixtureSettlement(TOURNAMENT, YEAR, ROUND, FIXTURE_1).phase),
            uint8(FixturePhase.Requested)
        );

        // Fail 2 → retryCount 2
        _fulfillErr(cvmRouter.lastRequestId(), bytes("fail-2"));
        assertEq(pbrSettle.getFixtureSettlement(TOURNAMENT, YEAR, ROUND, FIXTURE_1).retryCount, 2);

        // Fail 3 → retryCount 3
        _fulfillErr(cvmRouter.lastRequestId(), bytes("fail-3"));
        assertEq(pbrSettle.getFixtureSettlement(TOURNAMENT, YEAR, ROUND, FIXTURE_1).retryCount, 3);

        // Fail 4 → exhausted, phase None, no new request
        uint256 before = cvmRouter.requestCount();
        bytes32 lastBeforeExhaust = cvmRouter.lastRequestId();
        vm.expectEmit(true, true, false, true);
        emit Events.FixtureSettleRetryExhausted(TOURNAMENT, FIXTURE_1, 3, bytes("fail-4"));
        _fulfillErr(lastBeforeExhaust, bytes("fail-4"));

        assertEq(cvmRouter.requestCount(), before);
        FixtureSettlement memory f = pbrSettle.getFixtureSettlement(TOURNAMENT, YEAR, ROUND, FIXTURE_1);
        assertEq(uint8(f.phase), uint8(FixturePhase.None));
        assertEq(f.retryCount, 3);
        assertEq(uint8(pbrSettle.getRoundSettlement(TOURNAMENT, YEAR, ROUND).phase), uint8(RoundSettlePhase.Requested));
    }

    function test_retryFixtureSettle_afterExhaust() public {
        bytes32 requestId = _settleSimple();
        _fulfillErr(requestId, bytes("1"));
        _fulfillErr(cvmRouter.lastRequestId(), bytes("2"));
        _fulfillErr(cvmRouter.lastRequestId(), bytes("3"));
        _fulfillErr(cvmRouter.lastRequestId(), bytes("4"));

        // Permissionless manual retry.
        bytes32 retryId = pbrSettle.retryFixtureSettle(TOURNAMENT, YEAR, ROUND, FIXTURE_1);
        assertTrue(retryId != bytes32(0));
        // Manual retry does not increment retryCount.
        assertEq(pbrSettle.getFixtureSettlement(TOURNAMENT, YEAR, ROUND, FIXTURE_1).retryCount, 3);
        assertEq(
            uint8(pbrSettle.getFixtureSettlement(TOURNAMENT, YEAR, ROUND, FIXTURE_1).phase),
            uint8(FixturePhase.Requested)
        );

        _fulfillOkSimple(retryId);
        assertEq(uint8(pbrSettle.getRoundSettlement(TOURNAMENT, YEAR, ROUND).phase), uint8(RoundSettlePhase.Complete));
        assertEq(
            uint8(pbrSettle.getFixtureSettlement(TOURNAMENT, YEAR, ROUND, FIXTURE_1).phase), uint8(FixturePhase.Proven)
        );
    }

    function test_retryFixtureSettle_revertsWhenNotExhausted() public {
        _settleSimple();
        bytes32 fid = pbrSettle.fixtureJobId(TOURNAMENT, YEAR, ROUND, FIXTURE_1);

        vm.expectRevert(abi.encodeWithSelector(Errors.FixtureNotRetryable.selector, fid, FixturePhase.Requested));
        pbrSettle.retryFixtureSettle(TOURNAMENT, YEAR, ROUND, FIXTURE_1);
    }

    function test_retryFixtureSettle_revertsRoundNotPending() public {
        bytes32 rid = pbrSettle.roundId(TOURNAMENT, YEAR, ROUND);
        vm.expectRevert(abi.encodeWithSelector(Errors.RoundNotSettlePending.selector, rid));
        pbrSettle.retryFixtureSettle(TOURNAMENT, YEAR, ROUND, FIXTURE_1);
    }

    function test_retryFixtureSettle_revertsWhenProven() public {
        bytes32 requestId = _settleSimple();
        _fulfillOkSimple(requestId);

        // Round Complete — retry blocked by RoundNotSettlePending first.
        bytes32 rid = pbrSettle.roundId(TOURNAMENT, YEAR, ROUND);
        vm.expectRevert(abi.encodeWithSelector(Errors.RoundNotSettlePending.selector, rid));
        pbrSettle.retryFixtureSettle(TOURNAMENT, YEAR, ROUND, FIXTURE_1);
    }

    function test_partialProgress_oneFailsOneSucceeds() public {
        _setFixtures(_twoFixtures(FIXTURE_1, FIXTURE_2));
        bytes32[] memory ids = _settleAsTreasury(UTILIZED);

        bytes32 f0 = _fixtureFromRequest(ids[0]);
        bytes32 f1 = _fixtureFromRequest(ids[1]);

        // Exhaust f0.
        _fulfillErr(ids[0], bytes("e1"));
        _fulfillErr(cvmRouter.lastRequestId(), bytes("e2"));
        _fulfillErr(cvmRouter.lastRequestId(), bytes("e3"));
        _fulfillErr(cvmRouter.lastRequestId(), bytes("e4"));

        assertEq(uint8(pbrSettle.getFixtureSettlement(TOURNAMENT, YEAR, ROUND, f0).phase), uint8(FixturePhase.None));

        // f1 still pending — succeed.
        _fulfillOk(ids[1], UTILIZED, keccak256("ok"));
        assertEq(uint8(pbrSettle.getFixtureSettlement(TOURNAMENT, YEAR, ROUND, f1).phase), uint8(FixturePhase.Proven));
        assertEq(pbrSettle.getRoundSettlement(TOURNAMENT, YEAR, ROUND).fixturesSettled, 1);
        assertEq(uint8(pbrSettle.getRoundSettlement(TOURNAMENT, YEAR, ROUND).phase), uint8(RoundSettlePhase.Requested));

        // Manual retry f0 → Complete.
        bytes32 retryId = pbrSettle.retryFixtureSettle(TOURNAMENT, YEAR, ROUND, f0);
        _fulfillOk(retryId, UTILIZED, keccak256("ok2"));
        assertEq(uint8(pbrSettle.getRoundSettlement(TOURNAMENT, YEAR, ROUND).phase), uint8(RoundSettlePhase.Complete));
    }

    function test_settleRound_canReopenAfterComplete() public {
        bytes32 requestId = _settleSimple();
        _fulfillOkSimple(requestId);
        assertEq(uint8(pbrSettle.getRoundSettlement(TOURNAMENT, YEAR, ROUND).phase), uint8(RoundSettlePhase.Complete));

        // Proven fixture blocks re-settle of same fixture id.
        vm.prank(address(treasury));
        vm.expectRevert(abi.encodeWithSelector(Errors.FixtureAlreadySettled.selector, FIXTURE_1));
        pbrSettle.settleRound(TOURNAMENT, YEAR, ROUND, UTILIZED);
    }

    function test_ids_deterministic() public view {
        bytes32 a = pbrSettle.roundId(TOURNAMENT, YEAR, ROUND);
        bytes32 b = pbrSettle.roundId(TOURNAMENT, YEAR, ROUND);
        assertEq(a, b);
        assertTrue(a != pbrSettle.roundId(TOURNAMENT, YEAR, ROUND + 1));

        bytes32 f = pbrSettle.fixtureJobId(TOURNAMENT, YEAR, ROUND, FIXTURE_1);
        assertEq(f, pbrSettle.fixtureJobId(TOURNAMENT, YEAR, ROUND, FIXTURE_1));
        assertTrue(f != pbrSettle.fixtureJobId(TOURNAMENT, YEAR, ROUND, FIXTURE_2));
    }

    function test_maxRetries_constant() public view {
        assertEq(pbrSettle.MAX_FIXTURE_SETTLE_RETRIES(), 3);
    }
}
