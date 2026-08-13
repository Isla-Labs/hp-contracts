// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PbrHistoricalErrors as Errors } from "@errors/data/PbrHistoricalErrors.sol";
import { PbrHistoricalEvents as Events } from "@events/data/PbrHistoricalEvents.sol";
import { Appearance, HistoricalDmsPhase, TournamentHistoricalDms } from "@types/data/PbrHistoricalTypes.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";
import { TournamentType } from "@types/registries/TournamentTypes.sol";

import { PbrHistoricalTestBase } from "./PbrHistoricalTestBase.sol";

contract PbrHistoricalTest is PbrHistoricalTestBase {
    // --------------------------------------------
    //  openHistorical — ACL / validation
    // --------------------------------------------

    function test_openHistorical_revertsUnauthorized() public {
        _seedSingleSeason(TOURNAMENT, SEASON_A, YEAR_A, 1);
        _setRoundFixtures(YEAR_A, 1, _oneFixture(FIXTURE_1));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.Unauthorized.selector);
        pbrHistorical.openHistorical(TOURNAMENT);
    }

    function test_openHistorical_bySquadStore() public {
        _seedSingleSeason(TOURNAMENT, SEASON_A, YEAR_A, 1);
        _setRoundFixtures(YEAR_A, 1, _oneFixture(FIXTURE_1));

        bytes32[] memory ids = _openAsSquadStore(TOURNAMENT);
        assertEq(ids.length, 1);
        assertEq(uint8(pbrHistorical.getFetchPhase(TOURNAMENT)), uint8(HistoricalDmsPhase.Running));
    }

    function test_openHistorical_revertsZeroTournamentId() public {
        vm.prank(address(roundManager));
        vm.expectRevert(Errors.ZeroId.selector);
        pbrHistorical.openHistorical(bytes32(0));
    }

    function test_openHistorical_revertsNoSeasons() public {
        // RoundManager has no seasons for TOURNAMENT.
        vm.prank(address(roundManager));
        vm.expectRevert(abi.encodeWithSelector(Errors.NoSeasons.selector, TOURNAMENT));
        pbrHistorical.openHistorical(TOURNAMENT);
    }

    function test_openHistorical_revertsEmptyFixtures() public {
        _seedSingleSeason(TOURNAMENT, SEASON_A, YEAR_A, 1);
        _setRoundFixtures(YEAR_A, 1, new bytes32[](0));

        vm.prank(address(roundManager));
        vm.expectRevert(abi.encodeWithSelector(Errors.EmptyFixtures.selector, TOURNAMENT, YEAR_A, uint32(1)));
        pbrHistorical.openHistorical(TOURNAMENT);
    }

    function test_openHistorical_revertsZeroFixtureId() public {
        _seedSingleSeason(TOURNAMENT, SEASON_A, YEAR_A, 1);
        _setRoundFixtures(YEAR_A, 1, _oneFixture(bytes32(0)));

        vm.prank(address(roundManager));
        vm.expectRevert(Errors.ZeroId.selector);
        pbrHistorical.openHistorical(TOURNAMENT);
    }

    function test_openHistorical_idempotentWhenRunning() public {
        bytes32 first = _openSimpleRound();
        assertTrue(first != bytes32(0));

        bytes32[] memory second = _openAsRoundManager(TOURNAMENT);
        assertEq(second.length, 0);
        assertEq(cvmRouter.requestCount(), 1);
    }

    function test_openHistorical_domesticWriteAppearances() public {
        _seedSingleSeason(TOURNAMENT, SEASON_A, YEAR_A, 1);
        _setRoundFixtures(YEAR_A, 1, _oneFixture(FIXTURE_1));

        vm.expectEmit(true, false, false, true);
        emit Events.HistoricalDmsOpened(TOURNAMENT, 1, true);

        _openAsRoundManager(TOURNAMENT);
        TournamentHistoricalDms memory state = pbrHistorical.getFetchState(TOURNAMENT);
        assertTrue(state.writeAppearances);
        assertEq(state.roundNumber, 1);
        assertEq(state.fixturesExpected, 1);
        assertEq(state.seasons.length, 1);
    }

    function test_openHistorical_nonDomesticSkipsAppearancesFlag() public {
        tournamentRegistry.setTournamentType(TOURNAMENT, TournamentType.CONTINENTAL);
        _seedSingleSeason(TOURNAMENT, SEASON_A, YEAR_A, 1);
        _setRoundFixtures(YEAR_A, 1, _oneFixture(FIXTURE_1));

        vm.expectEmit(true, false, false, true);
        emit Events.HistoricalDmsOpened(TOURNAMENT, 1, false);

        _openAsRoundManager(TOURNAMENT);
        assertFalse(pbrHistorical.getFetchState(TOURNAMENT).writeAppearances);
    }

    function test_openHistorical_fansOutFixtures() public {
        _seedSingleSeason(TOURNAMENT, SEASON_A, YEAR_A, 1);
        _setRoundFixtures(YEAR_A, 1, _twoFixtures(FIXTURE_1, FIXTURE_2));

        bytes32[] memory ids = _openAsRoundManager(TOURNAMENT);
        assertEq(ids.length, 2);
        assertEq(cvmRouter.requestCount(), 2);

        for (uint256 i; i < 2; ++i) {
            (address consumer, CvmJob job, bytes memory args) = cvmRouter.getPending(ids[i]);
            assertEq(consumer, address(pbrHistorical));
            assertEq(uint8(job), uint8(CvmJob.HistoricalDms));
            (bytes32 tournamentId, bytes32 seasonId, uint16 year, uint32 roundNumber, bytes32 fixtureId) =
                abi.decode(args, (bytes32, bytes32, uint16, uint32, bytes32));
            assertEq(tournamentId, TOURNAMENT);
            assertEq(seasonId, SEASON_A);
            assertEq(year, YEAR_A);
            assertEq(roundNumber, 1);
            assertTrue(fixtureId == FIXTURE_1 || fixtureId == FIXTURE_2);
        }
    }

    // --------------------------------------------
    //  Fulfill — apply / views
    // --------------------------------------------

    function test_fulfill_storesDigestAndAppearances_domestic() public {
        bytes32 requestId = _openSimpleRound();

        Appearance[] memory apps = new Appearance[](2);
        apps[0] = _appearance(FIXTURE_1, PLAYER_A, 1);
        apps[1] = _appearance(FIXTURE_1, PLAYER_B, 1);
        bytes32 digest = _digest(FIXTURE_1);

        vm.expectEmit(true, true, true, true);
        emit Events.RssDigestStored(FIXTURE_1, digest);

        _fulfillOk(requestId, FIXTURE_1, digest, apps);

        assertEq(pbrHistorical.getRssDigest(FIXTURE_1), digest);
        Appearance[] memory stored = pbrHistorical.getAppearances(FIXTURE_1);
        assertEq(stored.length, 2);
        assertEq(stored[0].playerId, PLAYER_A);

        assertEq(squadStore.recordCount(), 1);
        assertEq(squadStore.lastSeasonId(), SEASON_A);
        assertEq(squadStore.lastAppearanceCount(), 2);

        assertEq(uint8(pbrHistorical.getFetchPhase(TOURNAMENT)), uint8(HistoricalDmsPhase.Complete));
    }

    function test_fulfill_emptyAppearances_skipsSquadWrite() public {
        bytes32 requestId = _openSimpleRound();
        Appearance[] memory empty = new Appearance[](0);
        _fulfillOk(requestId, FIXTURE_1, _digest(FIXTURE_1), empty);

        assertEq(squadStore.recordCount(), 0);
        assertEq(pbrHistorical.getAppearances(FIXTURE_1).length, 0);
        assertEq(uint8(pbrHistorical.getFetchPhase(TOURNAMENT)), uint8(HistoricalDmsPhase.Complete));
    }

    function test_fulfill_nonDomestic_skipsSquadWrite() public {
        tournamentRegistry.setTournamentType(TOURNAMENT, TournamentType.DOMESTIC_CUP);
        _seedSingleSeason(TOURNAMENT, SEASON_A, YEAR_A, 1);
        _setRoundFixtures(YEAR_A, 1, _oneFixture(FIXTURE_1));
        bytes32 requestId = _openAsRoundManager(TOURNAMENT)[0];

        Appearance[] memory apps = new Appearance[](1);
        apps[0] = _appearance(FIXTURE_1, PLAYER_A, 1);
        _fulfillOk(requestId, FIXTURE_1, _digest(FIXTURE_1), apps);

        assertEq(squadStore.recordCount(), 0);
        assertEq(pbrHistorical.getAppearances(FIXTURE_1).length, 1);
    }

    function test_fulfill_revertsFixtureIdMismatch() public {
        bytes32 requestId = _openSimpleRound();
        Appearance[] memory apps = new Appearance[](0);

        vm.expectRevert(abi.encodeWithSelector(Errors.FixtureIdMismatch.selector, FIXTURE_1, FIXTURE_2));
        _fulfillOk(requestId, FIXTURE_2, _digest(FIXTURE_2), apps);
    }

    function test_fulfill_revertsZeroHash() public {
        bytes32 requestId = _openSimpleRound();
        Appearance[] memory apps = new Appearance[](0);

        vm.expectRevert(Errors.ZeroHash.selector);
        _fulfillOk(requestId, FIXTURE_1, bytes32(0), apps);
    }

    function test_fulfill_revertsZeroAppearanceIds() public {
        bytes32 requestId = _openSimpleRound();
        Appearance[] memory apps = new Appearance[](1);
        apps[0] = _appearance(FIXTURE_1, bytes32(0), 1);

        vm.expectRevert(Errors.ZeroId.selector);
        _fulfillOk(requestId, FIXTURE_1, _digest(FIXTURE_1), apps);
    }

    function test_fulfill_revertsAppearanceFixtureMismatch() public {
        bytes32 requestId = _openSimpleRound();
        Appearance[] memory apps = new Appearance[](1);
        apps[0] = _appearance(FIXTURE_2, PLAYER_A, 1);

        vm.expectRevert(abi.encodeWithSelector(Errors.FixtureIdMismatch.selector, FIXTURE_1, FIXTURE_2));
        _fulfillOk(requestId, FIXTURE_1, _digest(FIXTURE_1), apps);
    }

    function test_unknownOracleRequest_reverts() public {
        bytes32 fake = keccak256("unknown");
        vm.prank(address(cvmRouter));
        vm.expectRevert(abi.encodeWithSelector(Errors.UnknownOracleRequest.selector, fake));
        pbrHistorical.handleOracleFulfillment(fake, "", "");
    }

    // --------------------------------------------
    //  Fail / retry / partial progress
    // --------------------------------------------

    function test_fulfillErr_autoRetriesFixture() public {
        _seedSingleSeason(TOURNAMENT, SEASON_A, YEAR_A, 1);
        _setRoundFixtures(YEAR_A, 1, _twoFixtures(FIXTURE_1, FIXTURE_2));
        bytes32[] memory ids = _openAsRoundManager(TOURNAMENT);

        (,, bytes memory args0) = cvmRouter.getPending(ids[0]);
        (,,,, bytes32 failedFixture) = abi.decode(args0, (bytes32, bytes32, uint16, uint32, bytes32));
        (,, bytes memory args1) = cvmRouter.getPending(ids[1]);
        (,,,, bytes32 otherFixture) = abi.decode(args1, (bytes32, bytes32, uint16, uint32, bytes32));

        uint256 before = cvmRouter.requestCount();
        _fulfillErr(ids[0], bytes("oracle-fail"));

        // One new retry request for the failed fixture.
        assertEq(cvmRouter.requestCount(), before + 1);
        bytes32 retryId = cvmRouter.lastRequestId();
        assertTrue(retryId != ids[0] && retryId != ids[1]);

        // Other fixture still pending; fulfill it.
        _fulfillOkSimple(ids[1], otherFixture, 1);
        assertEq(uint8(pbrHistorical.getFetchPhase(TOURNAMENT)), uint8(HistoricalDmsPhase.Running));
        assertEq(pbrHistorical.getFetchState(TOURNAMENT).fixturesDone, 1);

        // Retry succeeds → round complete → Complete.
        _fulfillOkSimple(retryId, failedFixture, 1);
        assertEq(uint8(pbrHistorical.getFetchPhase(TOURNAMENT)), uint8(HistoricalDmsPhase.Complete));
    }

    function test_digestCollision_acrossRounds() public {
        // Round 1 and round 2 share the same fixtureId (data-bug path).
        _seedSingleSeason(TOURNAMENT, SEASON_A, YEAR_A, 2);
        _setRoundFixtures(YEAR_A, 1, _oneFixture(FIXTURE_1));
        _setRoundFixtures(YEAR_A, 2, _oneFixture(FIXTURE_1));

        bytes32 requestId = _openAsRoundManager(TOURNAMENT)[0];
        _fulfillOkSimple(requestId, FIXTURE_1, 1);

        // Advanced to round 2 with same fixture id.
        assertEq(pbrHistorical.getFetchState(TOURNAMENT).roundNumber, 2);
        bytes32 round2Request = cvmRouter.lastRequestId();

        Appearance[] memory apps = new Appearance[](0);
        vm.expectRevert(abi.encodeWithSelector(Errors.FixtureDigestExists.selector, FIXTURE_1));
        _fulfillOk(round2Request, FIXTURE_1, keccak256("other"), apps);
    }

    // --------------------------------------------
    //  Round / season advance → Complete
    // --------------------------------------------

    function test_advance_nextRoundThenComplete() public {
        _seedSingleSeason(TOURNAMENT, SEASON_A, YEAR_A, 2);
        _setRoundFixtures(YEAR_A, 1, _oneFixture(FIXTURE_1));
        _setRoundFixtures(YEAR_A, 2, _oneFixture(FIXTURE_2));

        bytes32 r1 = _openAsRoundManager(TOURNAMENT)[0];
        _fulfillOkSimple(r1, FIXTURE_1, 1);

        TournamentHistoricalDms memory state = pbrHistorical.getFetchState(TOURNAMENT);
        assertEq(uint8(state.phase), uint8(HistoricalDmsPhase.Running));
        assertEq(state.roundNumber, 2);
        assertEq(state.fixturesExpected, 1);
        assertEq(state.fixturesDone, 0);

        bytes32 r2 = cvmRouter.lastRequestId();
        _fulfillOkSimple(r2, FIXTURE_2, 2);

        assertEq(uint8(pbrHistorical.getFetchPhase(TOURNAMENT)), uint8(HistoricalDmsPhase.Complete));
        assertEq(pbrHistorical.getRssDigest(FIXTURE_1), _digest(FIXTURE_1));
        assertEq(pbrHistorical.getRssDigest(FIXTURE_2), _digest(FIXTURE_2));
    }

    function test_advance_nextSeasonThenComplete() public {
        _seedTwoSeasons(1);
        _setRoundFixtures(YEAR_A, 1, _oneFixture(FIXTURE_1));
        _setRoundFixtures(YEAR_B, 1, _oneFixture(FIXTURE_2));

        bytes32 r1 = _openAsRoundManager(TOURNAMENT)[0];
        _fulfillOkSimple(r1, FIXTURE_1, 1);

        TournamentHistoricalDms memory state = pbrHistorical.getFetchState(TOURNAMENT);
        assertEq(state.seasonIndex, 1);
        assertEq(state.roundNumber, 1);
        assertEq(state.seasons[1].seasonId, SEASON_B);

        bytes32 r2 = cvmRouter.lastRequestId();
        (,, bytes memory args) = cvmRouter.getPending(r2);
        (,, uint16 year,, bytes32 fixtureId) = abi.decode(args, (bytes32, bytes32, uint16, uint32, bytes32));
        assertEq(year, YEAR_B);
        assertEq(fixtureId, FIXTURE_2);

        _fulfillOkSimple(r2, FIXTURE_2, 1);
        assertEq(uint8(pbrHistorical.getFetchPhase(TOURNAMENT)), uint8(HistoricalDmsPhase.Complete));
    }

    function test_multiFixtureRound_completesWhenAllDone() public {
        _seedSingleSeason(TOURNAMENT, SEASON_A, YEAR_A, 1);
        _setRoundFixtures(YEAR_A, 1, _twoFixtures(FIXTURE_1, FIXTURE_2));
        bytes32[] memory ids = _openAsRoundManager(TOURNAMENT);

        _fulfillOkSimple(ids[0], FIXTURE_1, 1);
        assertEq(pbrHistorical.getFetchState(TOURNAMENT).fixturesDone, 1);
        assertEq(uint8(pbrHistorical.getFetchPhase(TOURNAMENT)), uint8(HistoricalDmsPhase.Running));

        // Decode which fixture ids[1] is.
        (,, bytes memory args) = cvmRouter.getPending(ids[1]);
        (,,,, bytes32 fixtureId) = abi.decode(args, (bytes32, bytes32, uint16, uint32, bytes32));
        _fulfillOkSimple(ids[1], fixtureId, 1);

        assertEq(uint8(pbrHistorical.getFetchPhase(TOURNAMENT)), uint8(HistoricalDmsPhase.Complete));
    }

    function test_fixtureJobId_deterministic() public view {
        bytes32 a = pbrHistorical.fixtureJobId(TOURNAMENT, YEAR_A, 1, FIXTURE_1);
        bytes32 b = pbrHistorical.fixtureJobId(TOURNAMENT, YEAR_A, 1, FIXTURE_1);
        bytes32 c = pbrHistorical.fixtureJobId(TOURNAMENT, YEAR_A, 2, FIXTURE_1);
        assertEq(a, b);
        assertTrue(a != c);
    }

    function test_idempotentAfterComplete() public {
        bytes32 requestId = _openSimpleRound();
        _fulfillOkSimple(requestId, FIXTURE_1, 1);
        assertEq(uint8(pbrHistorical.getFetchPhase(TOURNAMENT)), uint8(HistoricalDmsPhase.Complete));

        bytes32[] memory again = _openAsRoundManager(TOURNAMENT);
        assertEq(again.length, 0);
        assertEq(uint8(pbrHistorical.getFetchPhase(TOURNAMENT)), uint8(HistoricalDmsPhase.Complete));
    }
}
