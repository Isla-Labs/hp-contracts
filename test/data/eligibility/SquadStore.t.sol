// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { EligibilityErrors as Errors } from "@errors/data/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@events/data/EligibilityEvents.sol";
import { Appearance } from "@types/data/PbrHistoricalTypes.sol";
import {
    LeagueSquadFetch,
    MinutesStore,
    SCORE_WAD,
    SeasonSquadStep,
    SquadFetchPhase,
    SquadList,
    SQUAD_FETCH_PAGE_DONE
} from "@types/data/SquadStoreTypes.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";
import { Position } from "@types/registries/PlayerSetTypes.sol";

import { EligibilityTestBase } from "./EligibilityTestBase.sol";

contract SquadStoreTest is EligibilityTestBase {
    // --------------------------------------------
    //  Access / openLeague
    // --------------------------------------------

    function test_openLeague_onlyOrchestrator() public {
        bytes32[] memory seasons = new bytes32[](1);
        seasons[0] = SEASON_B;
        uint16[] memory years_ = new uint16[](1);
        years_[0] = YEAR_B;

        vm.expectRevert(Errors.Unauthorized.selector);
        squadStore.openLeague(LEAGUE, seasons, years_);
    }

    function test_openLeague_revertsZeroLeague() public {
        bytes32[] memory seasons = new bytes32[](1);
        seasons[0] = SEASON_B;
        uint16[] memory years_ = new uint16[](1);
        years_[0] = YEAR_B;

        vm.prank(orchestrator);
        vm.expectRevert(Errors.ZeroId.selector);
        squadStore.openLeague(bytes32(0), seasons, years_);
    }

    function test_openLeague_revertsLengthMismatch() public {
        bytes32[] memory seasons = new bytes32[](1);
        seasons[0] = SEASON_B;
        uint16[] memory years_ = new uint16[](2);
        years_[0] = YEAR_A;
        years_[1] = YEAR_B;

        vm.prank(orchestrator);
        vm.expectRevert(Errors.ArrayLengthsMismatch.selector);
        squadStore.openLeague(LEAGUE, seasons, years_);
    }

    function test_openLeague_emptySeasons_noOracle() public {
        bytes32[] memory seasons = new bytes32[](0);
        uint16[] memory years_ = new uint16[](0);

        vm.prank(orchestrator);
        bytes32 requestId = squadStore.openLeague(LEAGUE, seasons, years_);
        assertEq(requestId, bytes32(0));
        _assertPhase(SquadFetchPhase.None);
        assertEq(cvmRouter.requestCount(), 0);
    }

    function test_openLeague_sortsSeasonsAscending_andOpensHistorical() public {
        bytes32 requestId = _openLeagueTwoSeasons();
        assertTrue(requestId != bytes32(0));

        LeagueSquadFetch memory fetch = squadStore.getFetchState(LEAGUE);
        assertEq(uint8(fetch.phase), uint8(SquadFetchPhase.Historical));
        assertEq(uint8(fetch.step), uint8(SeasonSquadStep.FetchPages));
        assertEq(fetch.seasons.length, 2);
        assertEq(fetch.seasons[0].seasonId, SEASON_A);
        assertEq(fetch.seasons[0].seasonStartYear, YEAR_A);
        assertEq(fetch.seasons[1].seasonId, SEASON_B);
        assertEq(fetch.seasons[1].seasonStartYear, YEAR_B);
        assertEq(fetch.scoreBaseYear, YEAR_A);
        assertEq(fetch.pageCursor, 1);

        assertEq(uint8(_pendingJob(requestId)), uint8(CvmJob.HistoricalSquadSync));
        (,, bytes memory args) = cvmRouter.getPending(requestId);
        (bytes32 seasonId, uint16 year, SeasonSquadStep step, uint32 cursor, uint16 personsOffset) =
            abi.decode(args, (bytes32, uint16, SeasonSquadStep, uint32, uint16));
        assertEq(seasonId, SEASON_A);
        assertEq(year, YEAR_A);
        assertEq(uint8(step), uint8(SeasonSquadStep.FetchPages));
        assertEq(cursor, 1);
        assertEq(personsOffset, 0);
    }

    function test_openLeague_revertsDuplicateSeasonYear() public {
        bytes32[] memory seasons = new bytes32[](2);
        seasons[0] = SEASON_A;
        seasons[1] = SEASON_B;
        uint16[] memory years_ = new uint16[](2);
        years_[0] = YEAR_A;
        years_[1] = YEAR_A;

        vm.prank(orchestrator);
        vm.expectRevert(abi.encodeWithSelector(Errors.DuplicateSeasonYear.selector, YEAR_A));
        squadStore.openLeague(LEAGUE, seasons, years_);
    }

    function test_openLeague_revertsAlreadyActive() public {
        _openLeagueSingle(SEASON_B, YEAR_B);

        bytes32[] memory seasons = new bytes32[](1);
        seasons[0] = SEASON_B;
        uint16[] memory years_ = new uint16[](1);
        years_[0] = YEAR_B;

        vm.prank(orchestrator);
        vm.expectRevert(abi.encodeWithSelector(Errors.FetchAlreadyActive.selector, LEAGUE));
        squadStore.openLeague(LEAGUE, seasons, years_);
    }

    // --------------------------------------------
    //  FetchPages + SortChunks
    // --------------------------------------------

    function test_fetchAndSort_createsPlayerAndSquadList() public {
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);
        uint32 birth = _birthYearsAgo(25);

        _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_OUT, CLUB_A, birth));

        _assertPhase(SquadFetchPhase.Live);
        assertEq(squadStore.playerCount(), 1);
        assertEq(squadStore.playerIdAt(0), PLAYER_OUT);

        MinutesStore memory store = squadStore.getMinutesStore(PLAYER_OUT);
        assertEq(store.currentLeagueId, LEAGUE);
        assertEq(store.currentClubId, CLUB_A);
        assertEq(store.birthDate, birth);
        assertEq(store.startYearCurrentLeague, YEAR_B);
        assertEq(store.deactivatedAt, 0);

        SquadList memory list = squadStore.getSquadList(CLUB_A);
        assertEq(list.clubId, CLUB_A);
        assertEq(list.playerIds.length, 1);
        assertEq(list.playerIds[0], PLAYER_OUT);

        assertEq(squadStore.getLatestSeason(LEAGUE).seasonId, SEASON_B);
    }

    function test_fetchPages_multiPage_thenSort() public {
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);

        bytes32[] memory p1 = new bytes32[](1);
        bytes32[] memory c1 = new bytes32[](1);
        uint32[] memory b1 = new uint32[](1);
        p1[0] = PLAYER_GK;
        c1[0] = CLUB_A;
        b1[0] = _birthYearsAgo(30);

        _fulfill(requestId, _page(1, 2, 0, p1, c1, b1));
        requestId = cvmRouter.lastRequestId();
        assertEq(uint8(squadStore.getFetchState(LEAGUE).step), uint8(SeasonSquadStep.FetchPages));
        assertEq(squadStore.getFetchState(LEAGUE).pageCursor, 2);

        bytes32[] memory p2 = new bytes32[](1);
        bytes32[] memory c2 = new bytes32[](1);
        uint32[] memory b2 = new uint32[](1);
        p2[0] = PLAYER_OUT;
        c2[0] = CLUB_B;
        b2[0] = _birthYearsAgo(28);

        _fulfill(requestId, _page(2, SQUAD_FETCH_PAGE_DONE, 0, p2, c2, b2));
        _assertStep(SeasonSquadStep.SortChunks);
        _drainSortChunks(LEAGUE);

        assertEq(squadStore.playerCount(), 2);
        assertEq(squadStore.getSquadList(CLUB_A).playerIds[0], PLAYER_GK);
        assertEq(squadStore.getSquadList(CLUB_B).playerIds[0], PLAYER_OUT);
        _assertPhase(SquadFetchPhase.Live);
    }

    function test_fetchPages_revertsInvalidNextPage() public {
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);
        bytes32[] memory p = new bytes32[](1);
        bytes32[] memory c = new bytes32[](1);
        uint32[] memory b = new uint32[](1);
        p[0] = PLAYER_OUT;
        c[0] = CLUB_A;
        b[0] = _birthYearsAgo(25);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidNextPage.selector, uint16(1), uint16(5)));
        _fulfill(requestId, _page(1, 5, 0, p, c, b));
    }

    function test_fetchPages_oracleErr_clearsPending_keepsHistorical() public {
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);
        cvmRouter.fulfill(requestId, "", abi.encode("timeout"));

        LeagueSquadFetch memory fetch = squadStore.getFetchState(LEAGUE);
        assertEq(fetch.pendingRequestId, bytes32(0));
        assertEq(uint8(fetch.phase), uint8(SquadFetchPhase.Historical));
        assertEq(uint8(fetch.step), uint8(SeasonSquadStep.FetchPages));
    }

    function test_twoSeasonBootstrap_walksEarliestToLatest() public {
        bytes32 requestId = _openLeagueTwoSeasons();

        // Season A
        requestId = _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_OUT, CLUB_A, _birthYearsAgo(26)));
        assertEq(uint8(squadStore.getFetchPhase(LEAGUE)), uint8(SquadFetchPhase.Historical));
        assertEq(squadStore.getFetchState(LEAGUE).seasonIndex, 1);
        assertEq(uint8(squadStore.getFetchState(LEAGUE).step), uint8(SeasonSquadStep.FetchPages));

        // Season B — same player, club change
        _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_OUT, CLUB_B, _birthYearsAgo(26)));

        _assertPhase(SquadFetchPhase.Live);
        assertEq(squadStore.playerCount(), 1);
        MinutesStore memory store = squadStore.getMinutesStore(PLAYER_OUT);
        assertEq(store.currentClubId, CLUB_B);
        assertEq(store.startYearCurrentLeague, YEAR_A); // created in A; no league change
    }

    function test_sort_marksLeftLeague_whenPlayerAbsent() public {
        bytes32 requestId = _openLeagueTwoSeasons();

        // Season A: two players
        bytes32[] memory players = new bytes32[](2);
        bytes32[] memory clubs = new bytes32[](2);
        uint32[] memory births = new uint32[](2);
        players[0] = PLAYER_OUT;
        players[1] = PLAYER_LOW;
        clubs[0] = CLUB_A;
        clubs[1] = CLUB_A;
        births[0] = _birthYearsAgo(26);
        births[1] = _birthYearsAgo(27);

        _fulfill(requestId, _page(1, SQUAD_FETCH_PAGE_DONE, 0, players, clubs, births));
        requestId = _drainSortChunks(LEAGUE);

        // Season B: only PLAYER_OUT remains (removals may need a second SortChunks ack)
        _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_OUT, CLUB_A, _birthYearsAgo(26)));

        MinutesStore memory left = squadStore.getMinutesStore(PLAYER_LOW);
        assertEq(left.currentClubId, bytes32(0));
        assertEq(left.deactivatedAt, uint64(block.timestamp));
        assertEq(left.currentLeagueId, LEAGUE);

        // Pending left-league drained only via verifier
        vm.prank(address(verifier));
        bytes32[] memory pending = squadStore.takePendingLeftLeague();
        assertEq(pending.length, 1);
        assertEq(pending[0], PLAYER_LOW);
    }

    function test_sort_detectsClubAndLeagueChanges() public {
        bytes32 otherLeague = keccak256("laliga");
        bytes32 otherSeason = keccak256("laliga-2024");

        // Bootstrap EPL with player at CLUB_A
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);
        _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_OUT, CLUB_A, _birthYearsAgo(26)));

        // Open second league and move player there
        bytes32[] memory seasons = new bytes32[](1);
        seasons[0] = otherSeason;
        uint16[] memory years_ = new uint16[](1);
        years_[0] = YEAR_B;
        tournamentRegistry.setSeasonId(otherLeague, YEAR_B, otherSeason);
        tournamentRegistry.setFinalRound(otherLeague, YEAR_B, 38);
        tournamentRegistry.setPbrTreasury(otherLeague, address(treasury));

        vm.prank(orchestrator);
        requestId = squadStore.openLeague(otherLeague, seasons, years_);
        _ingestOneSeasonPage(otherLeague, requestId, _singlePlayerPage(PLAYER_OUT, CLUB_B, _birthYearsAgo(26)));

        MinutesStore memory store = squadStore.getMinutesStore(PLAYER_OUT);
        assertEq(store.currentLeagueId, otherLeague);
        assertEq(store.currentClubId, CLUB_B);
        assertEq(store.startYearCurrentLeague, YEAR_B);

        vm.prank(address(verifier));
        bytes32[] memory leagueChanged = squadStore.takePendingLeagueChanged();
        assertEq(leagueChanged.length, 1);
        assertEq(leagueChanged[0], PLAYER_OUT);

        vm.prank(address(verifier));
        bytes32[] memory clubChanged = squadStore.takePendingClubChanged();
        assertEq(clubChanged.length, 1);
        assertEq(clubChanged[0], PLAYER_OUT);
    }

    function test_liveTransition_kicksPbrHistorical_whenRoundsLive() public {
        _setRoundManagerLive();
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);
        _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_OUT, CLUB_A, _birthYearsAgo(25)));

        _assertPhase(SquadFetchPhase.Live);
        assertEq(pbrHistorical.openCount(), 1);
        assertEq(pbrHistorical.lastOpenedTournamentId(), LEAGUE);
    }

    function test_liveTransition_skipsPbrHistorical_whenRoundsNotLive() public {
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);
        _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_OUT, CLUB_A, _birthYearsAgo(25)));

        _assertPhase(SquadFetchPhase.Live);
        assertEq(pbrHistorical.openCount(), 0);
    }

    // --------------------------------------------
    //  Appearances / scoring
    // --------------------------------------------

    function test_recordAppearances_onlyPbrHistorical() public {
        Appearance[] memory apps = new Appearance[](0);
        vm.expectRevert(Errors.Unauthorized.selector);
        squadStore.recordAppearances(SEASON_B, YEAR_B, apps);
    }

    function test_recordAppearances_updatesMinutesPositionAndScore() public {
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);
        _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_OUT, CLUB_A, _birthYearsAgo(26)));

        _seedScore(SEASON_B, YEAR_B, PLAYER_OUT, Position.CM, 900);

        MinutesStore memory store = squadStore.getMinutesStore(PLAYER_OUT);
        assertEq(uint8(store.expectedPosition), uint8(Position.CM));
        assertEq(store.positionMinutes[uint8(Position.CM)], 900);
        assertEq(store.leagueMinutes.length, 1);
        assertEq(store.leagueMinutes[0].leagueId, LEAGUE);
        assertEq(store.leagueMinutes[0].weightedScoreWad, 900 * SCORE_WAD);
        assertEq(store.leagueMinutes[0].lastScoreGlobalRound, 1);
    }

    function test_recordAppearances_skipsUntrackedAndZeroMins() public {
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);
        _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_OUT, CLUB_A, _birthYearsAgo(26)));

        Appearance[] memory apps = new Appearance[](2);
        apps[0] = Appearance({
            fixtureId: bytes32(uint256(1)),
            playerId: keccak256("unknown"),
            roundNumber: 1,
            position: Position.ST,
            minsPlayed: 90
        });
        apps[1] = Appearance({
            fixtureId: bytes32(uint256(2)), playerId: PLAYER_OUT, roundNumber: 1, position: Position.ST, minsPlayed: 0
        });

        vm.prank(pbrHistoricalAddr);
        vm.expectEmit(false, false, false, true);
        emit Events.AppearancesRecorded(0);
        squadStore.recordAppearances(SEASON_B, YEAR_B, apps);

        assertEq(squadStore.getMinutesStore(PLAYER_OUT).leagueMinutes.length, 0);
    }

    function test_recordAppearances_expectedPosition_requiresStrictBeat() public {
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);
        _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_OUT, CLUB_A, _birthYearsAgo(26)));

        _recordAppearance(SEASON_B, YEAR_B, PLAYER_OUT, 1, Position.CM, 100);
        _recordAppearance(SEASON_B, YEAR_B, PLAYER_OUT, 2, Position.ST, 100); // tie — keep CM
        assertEq(uint8(squadStore.getMinutesStore(PLAYER_OUT).expectedPosition), uint8(Position.CM));

        _recordAppearance(SEASON_B, YEAR_B, PLAYER_OUT, 3, Position.ST, 1); // 101 > 100
        assertEq(uint8(squadStore.getMinutesStore(PLAYER_OUT).expectedPosition), uint8(Position.ST));
    }

    function test_recordAppearances_ignoresUnregisteredSeason() public {
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);
        _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_OUT, CLUB_A, _birthYearsAgo(26)));

        // Wrong season id for YEAR_B — minutes accumulate, score does not.
        bytes32 wrongSeason = keccak256("wrong");
        _recordAppearance(wrongSeason, YEAR_B, PLAYER_OUT, 1, Position.CM, 900);

        MinutesStore memory store = squadStore.getMinutesStore(PLAYER_OUT);
        assertEq(store.positionMinutes[uint8(Position.CM)], 900);
        assertEq(store.leagueMinutes.length, 0);
    }

    // --------------------------------------------
    //  Verify helpers / purge
    // --------------------------------------------

    function test_purgeIfStale_onlyAfterFiveYears() public {
        bytes32 requestId = _openLeagueTwoSeasons();

        bytes32[] memory players = new bytes32[](2);
        bytes32[] memory clubs = new bytes32[](2);
        uint32[] memory births = new uint32[](2);
        players[0] = PLAYER_OUT;
        players[1] = PLAYER_LOW;
        clubs[0] = CLUB_A;
        clubs[1] = CLUB_A;
        births[0] = _birthYearsAgo(26);
        births[1] = _birthYearsAgo(27);

        _fulfill(requestId, _page(1, SQUAD_FETCH_PAGE_DONE, 0, players, clubs, births));
        requestId = _drainSortChunks(LEAGUE);
        _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_OUT, CLUB_A, _birthYearsAgo(26)));

        // PLAYER_LOW deactivatedAt = now; not stale yet
        uint256 lowIndex = squadStore.playerIdAt(0) == PLAYER_LOW ? 0 : 1;
        vm.prank(address(verifier));
        assertFalse(squadStore.purgeIfStale(lowIndex));
        assertEq(squadStore.playerCount(), 2);

        vm.warp(block.timestamp + 5 * 365 days);
        // Index may have moved if we looked up before warp; re-resolve.
        lowIndex = squadStore.playerIdAt(0) == PLAYER_LOW ? 0 : 1;
        vm.prank(address(verifier));
        assertTrue(squadStore.purgeIfStale(lowIndex));
        assertEq(squadStore.playerCount(), 1);
        assertEq(squadStore.playerIdAt(0), PLAYER_OUT);
    }

    function test_takePending_onlyEligibilityVerifier() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        squadStore.takePendingLeftLeague();
    }

    function test_playerIds_pagination() public {
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);

        bytes32[] memory players = new bytes32[](3);
        bytes32[] memory clubs = new bytes32[](3);
        uint32[] memory births = new uint32[](3);
        players[0] = PLAYER_GK;
        players[1] = PLAYER_U21;
        players[2] = PLAYER_OUT;
        clubs[0] = CLUB_A;
        clubs[1] = CLUB_A;
        clubs[2] = CLUB_B;
        births[0] = _birthYearsAgo(30);
        births[1] = _birthYearsAgo(18);
        births[2] = _birthYearsAgo(26);

        _fulfill(requestId, _page(1, SQUAD_FETCH_PAGE_DONE, 0, players, clubs, births));
        _drainSortChunks(LEAGUE);

        bytes32[] memory page = squadStore.playerIds(1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], PLAYER_U21);
        assertEq(page[1], PLAYER_OUT);

        bytes32[] memory empty = squadStore.playerIds(10, 2);
        assertEq(empty.length, 0);
    }
}
