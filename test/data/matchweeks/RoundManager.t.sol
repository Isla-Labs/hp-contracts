// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { stdError } from "forge-std/StdError.sol";

import { RateLimit } from "@base/abstract/RateLimit.sol";
import { MatchweekErrors as Errors } from "@errors/data/MatchweekErrors.sol";
import { MatchweekEvents as Events } from "@events/data/MatchweekEvents.sol";
import { RoundFetchPhase, SeasonFetchStep, SeasonRef, TournamentRoundFetch } from "@types/data/RoundManagerTypes.sol";
import { SquadFetchPhase } from "@types/data/SquadStoreTypes.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";
import { RoundSchedule, TournamentType } from "@types/registries/TournamentTypes.sol";

import { RoundManagerTestBase } from "./RoundManagerTestBase.sol";

contract RoundManagerTest is RoundManagerTestBase {
    // --------------------------------------------
    //  openTournament — auth / validation
    // --------------------------------------------

    function test_openTournament_revertsUnauthorized() public {
        bytes32[] memory seasonIds = new bytes32[](1);
        seasonIds[0] = SEASON_A;
        uint16[] memory seasonYears = new uint16[](1);
        seasonYears[0] = YEAR_A;

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.Unauthorized.selector);
        roundManager.openTournament(TOURNAMENT, seasonIds, seasonYears);
    }

    function test_openTournament_revertsZeroTournamentId() public {
        bytes32[] memory seasonIds = new bytes32[](1);
        seasonIds[0] = SEASON_A;
        uint16[] memory seasonYears = new uint16[](1);
        seasonYears[0] = YEAR_A;

        vm.expectRevert(Errors.ZeroId.selector);
        _openTournament(bytes32(0), seasonIds, seasonYears);
    }

    function test_openTournament_revertsLengthMismatch() public {
        bytes32[] memory seasonIds = new bytes32[](2);
        seasonIds[0] = SEASON_A;
        seasonIds[1] = SEASON_B;
        uint16[] memory seasonYears = new uint16[](1);
        seasonYears[0] = YEAR_A;

        vm.expectRevert(Errors.ArrayLengthsMismatch.selector);
        _openTournament(TOURNAMENT, seasonIds, seasonYears);
    }

    function test_openTournament_revertsZeroSeasonId() public {
        bytes32[] memory seasonIds = new bytes32[](1);
        seasonIds[0] = bytes32(0);
        uint16[] memory seasonYears = new uint16[](1);
        seasonYears[0] = YEAR_A;

        vm.expectRevert(Errors.ZeroId.selector);
        _openTournament(TOURNAMENT, seasonIds, seasonYears);
    }

    function test_openTournament_revertsZeroYear() public {
        bytes32[] memory seasonIds = new bytes32[](1);
        seasonIds[0] = SEASON_A;
        uint16[] memory seasonYears = new uint16[](1);
        seasonYears[0] = 0;

        vm.expectRevert(Errors.ZeroId.selector);
        _openTournament(TOURNAMENT, seasonIds, seasonYears);
    }

    function test_openTournament_revertsDuplicateSeasonYear() public {
        bytes32[] memory seasonIds = new bytes32[](2);
        seasonIds[0] = SEASON_A;
        seasonIds[1] = SEASON_B;
        uint16[] memory seasonYears = new uint16[](2);
        seasonYears[0] = YEAR_A;
        seasonYears[1] = YEAR_A;

        vm.expectRevert(abi.encodeWithSelector(Errors.DuplicateSeasonYear.selector, YEAR_A));
        _openTournament(TOURNAMENT, seasonIds, seasonYears);
    }

    function test_openTournament_emptySeasons_noop() public {
        bytes32[] memory seasonIds = new bytes32[](0);
        uint16[] memory seasonYears = new uint16[](0);

        vm.expectEmit(true, false, false, true);
        emit Events.RoundFetchQueued(TOURNAMENT, seasonIds, seasonYears, RoundFetchPhase.None);

        bytes32 requestId = _openTournament(TOURNAMENT, seasonIds, seasonYears);
        assertEq(requestId, bytes32(0));
        assertEq(uint8(roundManager.getFetchPhase(TOURNAMENT)), uint8(RoundFetchPhase.None));
        assertEq(cvmRouter.requestCount(), 0);
    }

    function test_openTournament_sortsSeasonsAscending() public {
        bytes32[] memory seasonIds = new bytes32[](2);
        seasonIds[0] = SEASON_B;
        seasonIds[1] = SEASON_A;
        uint16[] memory seasonYears = new uint16[](2);
        seasonYears[0] = YEAR_B;
        seasonYears[1] = YEAR_A;

        bytes32 requestId = _openTournament(TOURNAMENT, seasonIds, seasonYears);
        assertTrue(requestId != bytes32(0));

        TournamentRoundFetch memory state = roundManager.getFetchState(TOURNAMENT);
        assertEq(uint8(state.phase), uint8(RoundFetchPhase.Historical));
        assertEq(uint8(state.step), uint8(SeasonFetchStep.FormatRounds));
        assertEq(state.seasonIndex, 0);
        assertEq(state.seasons.length, 2);
        assertEq(state.seasons[0].seasonId, SEASON_A);
        assertEq(state.seasons[0].seasonStartYear, YEAR_A);
        assertEq(state.seasons[1].seasonId, SEASON_B);
        assertEq(state.seasons[1].seasonStartYear, YEAR_B);

        (address consumer, CvmJob job, bytes memory args) = cvmRouter.getPending(requestId);
        assertEq(consumer, address(roundManager));
        assertEq(uint8(job), uint8(CvmJob.HistoricalRoundSync));

        (bytes32 seasonId, uint16 year, SeasonFetchStep step, uint32 cursor) =
            abi.decode(args, (bytes32, uint16, SeasonFetchStep, uint32));
        assertEq(seasonId, SEASON_A);
        assertEq(year, YEAR_A);
        assertEq(uint8(step), uint8(SeasonFetchStep.FormatRounds));
        assertEq(cursor, 0);
    }

    function test_openTournament_revertsAlreadyActive() public {
        _openSingleSeason(TOURNAMENT, SEASON_A, YEAR_A);

        bytes32[] memory seasonIds = new bytes32[](1);
        seasonIds[0] = SEASON_B;
        uint16[] memory seasonYears = new uint16[](1);
        seasonYears[0] = YEAR_B;

        vm.expectRevert(abi.encodeWithSelector(Errors.FetchAlreadyActive.selector, TOURNAMENT));
        _openTournament(TOURNAMENT, seasonIds, seasonYears);
    }

    // --------------------------------------------
    //  Historical Format → Upsert → Live
    // --------------------------------------------

    function test_format_revertsEmptyRounds() public {
        bytes32 requestId = _openSingleSeason(TOURNAMENT, SEASON_A, YEAR_A);
        RoundSchedule[] memory empty = new RoundSchedule[](0);
        vm.expectRevert(Errors.EmptyRounds.selector);
        _fulfillHistorical(requestId, empty);
    }

    function test_format_revertsRoundCountMismatch() public {
        bytes32 requestId = _openSingleSeason(TOURNAMENT, SEASON_A, YEAR_A);
        vm.expectRevert(abi.encodeWithSelector(Errors.RoundCountMismatch.selector, FINAL_ROUND, uint32(5)));
        _fulfillHistorical(requestId, _formatRounds(5));
    }

    function test_format_stripsFixtureIds() public {
        bytes32 requestId = _openSingleSeason(TOURNAMENT, SEASON_A, YEAR_A);
        _fulfillHistorical(requestId, _formatRoundsWithFixtures(FINAL_ROUND, 3));

        RoundSchedule memory r = tournamentRegistry.getRound(TOURNAMENT, YEAR_A, 1);
        assertEq(r.fixtureIds.length, 0);
        assertEq(tournamentRegistry.lastUpsertBatchSize(), FINAL_ROUND);

        TournamentRoundFetch memory state = roundManager.getFetchState(TOURNAMENT);
        assertEq(uint8(state.step), uint8(SeasonFetchStep.UpsertFixtures));
        assertEq(state.fixtureRoundCursor, 1);
        assertEq(state.finalRound, FINAL_ROUND);
        assertTrue(state.pendingRequestId != bytes32(0));
    }

    function test_upsert_pagesUntilLive() public {
        squadStore.setFetchPhase(TOURNAMENT, SquadFetchPhase.None);
        _openSingleSeason(TOURNAMENT, SEASON_A, YEAR_A);

        bytes32 requestId = cvmRouter.lastRequestId();
        _fulfillHistorical(requestId, _formatRounds(FINAL_ROUND));

        requestId = cvmRouter.lastRequestId();
        (,, bytes memory args) = cvmRouter.getPending(requestId);
        (,, SeasonFetchStep step, uint32 cursor) = abi.decode(args, (bytes32, uint16, SeasonFetchStep, uint32));
        assertEq(uint8(step), uint8(SeasonFetchStep.UpsertFixtures));
        assertEq(cursor, 1);

        _fulfillHistorical(requestId, _fixturePage(1, 10, 2));

        requestId = cvmRouter.lastRequestId();
        (,, args) = cvmRouter.getPending(requestId);
        (,,, cursor) = abi.decode(args, (bytes32, uint16, SeasonFetchStep, uint32));
        assertEq(cursor, 11);

        _fulfillHistorical(requestId, _fixturePage(11, 2, 2));

        assertEq(uint8(roundManager.getFetchPhase(TOURNAMENT)), uint8(RoundFetchPhase.Live));
        SeasonRef memory latest = roundManager.getLatestSeason(TOURNAMENT);
        assertEq(latest.seasonId, SEASON_A);
        assertEq(latest.seasonStartYear, YEAR_A);

        // Domestic + squads not Live → no historical kick.
        assertEq(pbrHistorical.openCount(), 0);
    }

    function test_multiSeason_advancesThenLive() public {
        squadStore.setFetchPhase(TOURNAMENT, SquadFetchPhase.Live);

        bytes32[] memory seasonIds = new bytes32[](2);
        seasonIds[0] = SEASON_A;
        seasonIds[1] = SEASON_B;
        uint16[] memory seasonYears = new uint16[](2);
        seasonYears[0] = YEAR_A;
        seasonYears[1] = YEAR_B;

        _drainHistoricalToLive(TOURNAMENT, seasonIds, seasonYears);

        TournamentRoundFetch memory state = roundManager.getFetchState(TOURNAMENT);
        assertEq(state.seasonIndex, 1);
        assertEq(state.seasons[1].seasonId, SEASON_B);
        assertEq(pbrHistorical.openCount(), 1);
        assertEq(pbrHistorical.lastOpenedTournamentId(), TOURNAMENT);
    }

    function test_peerKick_domesticWhenSquadsLive() public {
        squadStore.setFetchPhase(TOURNAMENT, SquadFetchPhase.Live);
        _drainSingleToLive(TOURNAMENT, SEASON_A, YEAR_A);
        assertEq(pbrHistorical.openCount(), 1);
    }

    function test_peerKick_nonDomesticImmediate() public {
        tournamentRegistry.setTournamentType(TOURNAMENT, TournamentType.CONTINENTAL);
        squadStore.setFetchPhase(TOURNAMENT, SquadFetchPhase.None);
        _openSingleSeason(TOURNAMENT, SEASON_A, YEAR_A);
        _drainSeasonHistorical(YEAR_A);

        assertEq(uint8(roundManager.getFetchPhase(TOURNAMENT)), uint8(RoundFetchPhase.Live));
        assertEq(pbrHistorical.openCount(), 1);
    }

    function test_oracleErr_clearsPendingNoRetry() public {
        bytes32 requestId = _openSingleSeason(TOURNAMENT, SEASON_A, YEAR_A);

        vm.expectEmit(true, true, false, true);
        emit Events.RoundOracleFailed(requestId, TOURNAMENT, bytes("fail"));
        _fulfillHistoricalErr(requestId, bytes("fail"));

        TournamentRoundFetch memory state = roundManager.getFetchState(TOURNAMENT);
        assertEq(state.pendingRequestId, bytes32(0));
        assertEq(uint8(state.phase), uint8(RoundFetchPhase.Historical));
        assertEq(uint8(state.step), uint8(SeasonFetchStep.FormatRounds));
        // No auto-retry — request count stays at the failed open.
        assertEq(cvmRouter.requestCount(), 1);
    }

    // --------------------------------------------
    //  Live refreshRounds
    // --------------------------------------------

    function test_refreshRounds_revertsNotLive() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.NotLive.selector, TOURNAMENT));
        roundManager.refreshRounds(TOURNAMENT);
    }

    function test_refreshRounds_revertsZeroId() public {
        vm.expectRevert(Errors.ZeroId.selector);
        roundManager.refreshRounds(bytes32(0));
    }

    function test_refreshRounds_rateLimited() public {
        _drainSingleToLive(TOURNAMENT, SEASON_A, YEAR_A);

        bytes32 requestId = roundManager.refreshRounds(TOURNAMENT);
        assertTrue(requestId != bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(RateLimit.RateLimited.selector, block.timestamp + REFRESH_COOLDOWN));
        roundManager.refreshRounds(TOURNAMENT);
    }

    function test_refreshRounds_revertsPending() public {
        _drainSingleToLive(TOURNAMENT, SEASON_A, YEAR_A);
        bytes32 pending = roundManager.refreshRounds(TOURNAMENT);

        vm.warp(block.timestamp + REFRESH_COOLDOWN + 1);
        vm.expectRevert(abi.encodeWithSelector(Errors.OracleRequestPending.selector, pending));
        roundManager.refreshRounds(TOURNAMENT);
    }

    function test_refreshRounds_fullRefreshStaysLive() public {
        _drainSingleToLive(TOURNAMENT, SEASON_A, YEAR_A);
        uint256 opensBefore = pbrHistorical.openCount();

        bytes32 requestId = roundManager.refreshRounds(TOURNAMENT);
        (, CvmJob job, bytes memory args) = cvmRouter.getPending(requestId);
        assertEq(uint8(job), uint8(CvmJob.RoundSync));

        (bytes32 tournamentId, bytes32 seasonId, uint16 year, SeasonFetchStep step, uint32 cursor) =
            abi.decode(args, (bytes32, bytes32, uint16, SeasonFetchStep, uint32));
        assertEq(tournamentId, TOURNAMENT);
        assertEq(seasonId, SEASON_A);
        assertEq(year, YEAR_A);
        assertEq(uint8(step), uint8(SeasonFetchStep.FormatRounds));
        assertEq(cursor, 0);

        _fulfillLiveRefresh(requestId, _formatRounds(FINAL_ROUND));
        requestId = cvmRouter.lastRequestId();
        _fulfillLiveRefresh(requestId, _fixturePage(1, 10, 2));
        requestId = cvmRouter.lastRequestId();
        _fulfillLiveRefresh(requestId, _fixturePage(11, 2, 2));

        assertEq(uint8(roundManager.getFetchPhase(TOURNAMENT)), uint8(RoundFetchPhase.Live));
        assertEq(pbrHistorical.openCount(), opensBefore);
    }

    function test_openSeason_domesticAdoptsAndFormats() public {
        _drainSingleToLive(TOURNAMENT, SEASON_A, YEAR_A);
        _seedFinalRound(TOURNAMENT, YEAR_C, FINAL_ROUND);

        bytes32 requestId = roundManager.refreshRounds(TOURNAMENT);
        _fulfillLiveOpenSeason(requestId, SEASON_C, YEAR_C, FINAL_ROUND);

        assertEq(tournamentInitializer.openSeasonCount(), 1);
        assertEq(tournamentInitializer.lastTournamentId(), TOURNAMENT);
        assertEq(tournamentInitializer.lastSeasonId(), SEASON_C);
        assertEq(tournamentInitializer.lastSeasonStartYear(), YEAR_C);
        assertEq(tournamentInitializer.lastFinalRound(), FINAL_ROUND);

        assertEq(squadStore.adoptSeasonCount(), 1);
        assertEq(squadStore.lastAdoptLeagueId(), TOURNAMENT);
        assertEq(squadStore.lastAdoptSeasonId(), SEASON_C);
        assertEq(squadStore.lastAdoptYear(), YEAR_C);

        TournamentRoundFetch memory state = roundManager.getFetchState(TOURNAMENT);
        assertEq(state.seasons.length, 2);
        assertEq(state.seasons[1].seasonId, SEASON_C);
        assertEq(uint8(state.step), uint8(SeasonFetchStep.FormatRounds));
        assertTrue(state.pendingRequestId != bytes32(0));

        (, CvmJob job,) = cvmRouter.getPending(state.pendingRequestId);
        assertEq(uint8(job), uint8(CvmJob.RoundSync));
    }

    function test_openSeason_nonDomesticSkipsAdopt() public {
        tournamentRegistry.setTournamentType(TOURNAMENT, TournamentType.DOMESTIC_CUP);
        squadStore.setFetchPhase(TOURNAMENT, SquadFetchPhase.None);
        _openSingleSeason(TOURNAMENT, SEASON_A, YEAR_A);
        _drainSeasonHistorical(YEAR_A);
        _seedFinalRound(TOURNAMENT, YEAR_C, FINAL_ROUND);

        bytes32 requestId = roundManager.refreshRounds(TOURNAMENT);
        _fulfillLiveOpenSeason(requestId, SEASON_C, YEAR_C, FINAL_ROUND);

        assertEq(tournamentInitializer.openSeasonCount(), 1);
        assertEq(squadStore.adoptSeasonCount(), 0);
    }

    function test_openSeason_revertsDuplicateYear() public {
        _drainSingleToLive(TOURNAMENT, SEASON_A, YEAR_A);
        bytes32 requestId = roundManager.refreshRounds(TOURNAMENT);

        vm.expectRevert(abi.encodeWithSelector(Errors.DuplicateSeasonYear.selector, YEAR_A));
        _fulfillLiveOpenSeason(requestId, SEASON_B, YEAR_A, FINAL_ROUND);
    }

    function test_openSeason_revertsOlderYear() public {
        _drainSingleToLive(TOURNAMENT, SEASON_B, YEAR_B);
        bytes32 requestId = roundManager.refreshRounds(TOURNAMENT);

        vm.expectRevert(abi.encodeWithSelector(Errors.DuplicateSeasonYear.selector, YEAR_A));
        _fulfillLiveOpenSeason(requestId, SEASON_A, YEAR_A, FINAL_ROUND);
    }

    function test_openSeason_revertsZeroIds() public {
        _drainSingleToLive(TOURNAMENT, SEASON_A, YEAR_A);
        bytes32 requestId = roundManager.refreshRounds(TOURNAMENT);

        vm.expectRevert(Errors.ZeroId.selector);
        _fulfillLiveOpenSeason(requestId, bytes32(0), YEAR_C, FINAL_ROUND);
    }

    function test_live_unexpectedKindReverts() public {
        _drainSingleToLive(TOURNAMENT, SEASON_A, YEAR_A);
        bytes32 requestId = roundManager.refreshRounds(TOURNAMENT);

        // Solidity 0.8 panics on out-of-range enum cast before UnexpectedLiveKind can fire.
        vm.expectRevert(stdError.enumConversionError);
        cvmRouter.fulfill(requestId, abi.encode(uint8(99), bytes("")), "");
    }

    // --------------------------------------------
    //  Manual writes / views
    // --------------------------------------------

    function test_setFinalRound_alwaysReverts() public {
        vm.prank(orchestrator);
        vm.expectRevert(Errors.InvalidFinalRound.selector);
        roundManager.setFinalRound(TOURNAMENT, YEAR_A, 38);
    }

    function test_upsertRound_passThrough() public {
        RoundSchedule memory round =
            RoundSchedule({ roundNumber: 1, startTime: 100, endTime: 200, fixtureIds: new bytes32[](1) });
        round.fixtureIds[0] = keccak256("f1");

        _upsertRound(TOURNAMENT, YEAR_A, round);
        assertEq(tournamentRegistry.upsertRoundCount(), 1);
        assertTrue(roundManager.isRoundPublished(TOURNAMENT, YEAR_A, 1));

        RoundSchedule memory stored = roundManager.getRound(TOURNAMENT, YEAR_A, 1);
        assertEq(stored.roundNumber, 1);
        assertEq(stored.fixtureIds[0], keccak256("f1"));
    }

    function test_upsertRounds_passThrough() public {
        RoundSchedule[] memory rounds = _fixturePage(1, 2, 1);
        _upsertRounds(TOURNAMENT, YEAR_A, rounds);
        assertEq(tournamentRegistry.upsertRoundsCount(), 1);
        assertEq(tournamentRegistry.lastUpsertBatchSize(), 2);
    }

    function test_upsert_revertsUnauthorized() public {
        RoundSchedule memory round =
            RoundSchedule({ roundNumber: 1, startTime: 1, endTime: 2, fixtureIds: new bytes32[](0) });
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.Unauthorized.selector);
        roundManager.upsertRound(TOURNAMENT, YEAR_A, round);
    }

    function test_views_getFinalRound() public view {
        assertEq(roundManager.getFinalRound(TOURNAMENT, YEAR_A), FINAL_ROUND);
    }

    function test_getLatestSeason_revertsEmpty() public {
        vm.expectRevert(Errors.ZeroId.selector);
        roundManager.getLatestSeason(TOURNAMENT);
    }

    function test_unknownOracleRequest_reverts() public {
        bytes32 fake = keccak256("unknown");
        vm.prank(address(cvmRouter));
        vm.expectRevert(abi.encodeWithSelector(Errors.UnknownOracleRequest.selector, fake));
        roundManager.handleOracleFulfillment(fake, "", "");
    }

    function test_constructor_defaults() public view {
        assertEq(roundManager.FIXTURE_ROUNDS_PER_REQUEST(), 10);
        assertEq(roundManager.cooldown(), REFRESH_COOLDOWN);
    }
}
