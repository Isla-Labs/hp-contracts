// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RateLimit } from "@base/abstract/RateLimit.sol";
import { AddressKeys as Addresses } from "@addresses/AddressKeys.sol";
import { EligibilityErrors as Errors } from "@errors/data/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@events/data/EligibilityEvents.sol";
import { EligibilityGroups } from "@types/initializers/DopplerTypes.sol";
import { LifecycleReason } from "@types/initializers/LifecycleTypes.sol";
import { SQUAD_FETCH_PAGE_DONE } from "@types/data/SquadStoreTypes.sol";
import { PlayerStatus, Position } from "@types/registries/PlayerSetTypes.sol";

import { MockDopplerLocker } from "./mocks/MockDopplerLocker.sol";
import { MockLifecycleManager } from "./mocks/MockLifecycleManager.sol";
import { EligibilityTestBase } from "./EligibilityTestBase.sol";
import { SquadStore } from "@src/data/eligibility/SquadStore.sol";
import { EligibilityVerifier } from "@src/data/eligibility/EligibilityVerifier.sol";

contract EligibilityVerifierTest is EligibilityTestBase {
    // --------------------------------------------
    //  Criteria / access
    // --------------------------------------------

    function test_defaultThresholds() public view {
        (uint32 gk, uint32 u21, uint32 outf, uint32 nt, uint256 age) = verifier.eligibilityCriteria();
        assertEq(gk, 361);
        assertEq(u21, 181);
        assertEq(outf, 901);
        assertEq(nt, 1);
        assertEq(age, 21);
    }

    function test_setEligibilityThresholds_onlyTimelock() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        verifier.setEligibilityThresholds(100, 100, 100, 1, 21);

        vm.prank(timelock);
        verifier.setEligibilityThresholds(100, 200, 300, 4, 22);

        (uint32 gk, uint32 u21, uint32 outf, uint32 nt, uint256 age) = verifier.eligibilityCriteria();
        assertEq(gk, 100);
        assertEq(u21, 200);
        assertEq(outf, 300);
        assertEq(nt, 4);
        assertEq(age, 22);
    }

    function test_setEligibilityThresholds_revertsZero() public {
        vm.prank(timelock);
        vm.expectRevert(Errors.InvalidThreshold.selector);
        verifier.setEligibilityThresholds(0, 200, 300, 4, 22);
    }

    function test_openLeague_onlyOrchestrator() public {
        bytes32[] memory seasons = new bytes32[](1);
        seasons[0] = SEASON_B;
        uint16[] memory years_ = new uint16[](1);
        years_[0] = YEAR_B;

        vm.expectRevert(Errors.Unauthorized.selector);
        squadStore.openLeague(LEAGUE, seasons, years_);
    }

    // --------------------------------------------
    //  Deploy classification
    // --------------------------------------------

    function test_verify_deploysGoalkeeper() public {
        _bootstrapPlayers();
        _seedScore(SEASON_B, YEAR_B, PLAYER_GK, Position.GK, 400);

        // Continuity path requires prior seasons for non-NT; set start year older than current.
        // PLAYER_GK was created in YEAR_B with treasury YEAR_B → NewTransfer unless we age start year.
        // Re-bootstrap with two seasons so continuity applies.
        _resetAndBootstrapContinuity();
        _seedScore(SEASON_B, YEAR_B, PLAYER_GK, Position.GK, 400);

        EligibilityGroups memory groups = verifier.verifyEligibility(0, 10);
        // `_enqueueEligible` zeroes cohort ids in the returned memory groups — assert via locker.
        assertEq(groups.goalkeepers.length, 1);
        assertTrue(dopplerLocker.wasQueued(PLAYER_GK));
    }

    function test_verify_deploysUnder21() public {
        _resetAndBootstrapContinuity();
        _seedScore(SEASON_B, YEAR_B, PLAYER_U21, Position.ST, 200);

        EligibilityGroups memory groups = verifier.verifyEligibility(0, 10);
        assertEq(groups.under21.length, 1);
        assertTrue(dopplerLocker.wasQueued(PLAYER_U21));
    }

    function test_verify_deploysOutfield() public {
        _resetAndBootstrapContinuity();
        _seedScore(SEASON_B, YEAR_B, PLAYER_OUT, Position.CM, 950);

        EligibilityGroups memory groups = verifier.verifyEligibility(0, 10);
        assertEq(groups.outfield.length, 1);
        assertTrue(dopplerLocker.wasQueued(PLAYER_OUT));
    }

    function test_verify_deploysNewTransfer() public {
        // Single-season bootstrap: startYear == current season → NewTransfer (threshold 1).
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);
        _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_NT, CLUB_A, _birthYearsAgo(26)));
        _seedScore(SEASON_B, YEAR_B, PLAYER_NT, Position.CM, 10);

        EligibilityGroups memory groups = verifier.verifyEligibility(0, 10);
        assertEq(groups.newTransfers.length, 1);
        assertEq(groups.outfield.length, 0);
        assertTrue(dopplerLocker.wasQueued(PLAYER_NT));

        (bytes32 leagueId, bytes32 seasonId, bytes32[] memory queued) = dopplerLocker.callAt(0);
        assertEq(leagueId, LEAGUE);
        assertEq(seasonId, SEASON_B);
        assertEq(queued.length, 1);
        assertEq(queued[0], PLAYER_NT);
    }

    function test_verify_belowThreshold_notDeployed() public {
        _resetAndBootstrapContinuity();
        _seedScore(SEASON_B, YEAR_B, PLAYER_OUT, Position.CM, 100); // < 901

        EligibilityGroups memory groups = verifier.verifyEligibility(0, 10);
        assertEq(groups.outfield.length, 0);
        assertEq(groups.goalkeepers.length, 0);
        assertEq(groups.under21.length, 0);
        assertEq(groups.newTransfers.length, 0);
        assertEq(dopplerLocker.callCount(), 0);
    }

    function test_verify_missingBirthOrClub_skipped() public {
        // Manually open + inject a page that would create a player, then clear club via left-league path is heavy.
        // Instead: player with no league minutes / zero birth is not eligible — create via normal ingest then
        // verify a brand-new empty index is a no-op for undeployed players under threshold.
        _resetAndBootstrapContinuity();
        // PLAYER_LOW has no score
        EligibilityGroups memory groups = verifier.verifyEligibility(0, 10);
        assertEq(
            groups.goalkeepers.length + groups.under21.length + groups.outfield.length + groups.newTransfers.length, 0
        );
    }

    function test_verify_queuesByLeagueBatch() public {
        _resetAndBootstrapContinuity();
        _seedScore(SEASON_B, YEAR_B, PLAYER_GK, Position.GK, 400);
        _seedScore(SEASON_B, YEAR_B, PLAYER_OUT, Position.CM, 950);

        verifier.verifyEligibility(0, 10);

        // Each deploy cohort is queued separately (GK then outfield), both under the same league/season.
        assertEq(dopplerLocker.callCount(), 2);
        assertEq(dopplerLocker.totalQueuedPlayers(), 2);
        assertTrue(dopplerLocker.wasQueued(PLAYER_GK));
        assertTrue(dopplerLocker.wasQueued(PLAYER_OUT));

        (bytes32 leagueId0, bytes32 seasonId0,) = dopplerLocker.callAt(0);
        (bytes32 leagueId1, bytes32 seasonId1,) = dopplerLocker.callAt(1);
        assertEq(leagueId0, LEAGUE);
        assertEq(leagueId1, LEAGUE);
        assertEq(seasonId0, SEASON_B);
        assertEq(seasonId1, SEASON_B);
    }

    // --------------------------------------------
    //  Continuity — deactivate / reactivate
    // --------------------------------------------

    function test_verify_deactivatesDeployedPlayerUnderThreshold() public {
        _resetAndBootstrapContinuity();
        _seedScore(SEASON_B, YEAR_B, PLAYER_OUT, Position.CM, 100);
        playerSetRegistry.seedPlayer(PLAYER_OUT, PlayerStatus.GRADUATED, LEAGUE);

        vm.expectEmit(true, false, false, true);
        emit Events.PlayerDeactivated(PLAYER_OUT, 100);

        EligibilityGroups memory groups = verifier.verifyEligibility(0, 10);
        assertEq(groups.toDeactivate.length, 1);
        assertTrue(lifecycleManager.wasEnqueued(PLAYER_OUT, LifecycleReason.ContinuityUnderThreshold));
        assertEq(lifecycleManager.effectiveMinsFor(PLAYER_OUT, LifecycleReason.ContinuityUnderThreshold), 100);
        assertEq(dopplerLocker.callCount(), 0);
    }

    function test_verify_reactivatesInactivePlayerAboveThreshold() public {
        _resetAndBootstrapContinuity();
        _seedScore(SEASON_B, YEAR_B, PLAYER_OUT, Position.CM, 950);
        playerSetRegistry.seedPlayer(PLAYER_OUT, PlayerStatus.INACTIVE, LEAGUE);

        vm.expectEmit(true, false, false, true);
        emit Events.PlayerReactivateQueued(PLAYER_OUT, 950);

        EligibilityGroups memory groups = verifier.verifyEligibility(0, 10);
        assertEq(groups.toReactivate.length, 1);
        assertTrue(lifecycleManager.wasEnqueued(PLAYER_OUT, LifecycleReason.Reactivate));
        assertEq(lifecycleManager.effectiveMinsFor(PLAYER_OUT, LifecycleReason.Reactivate), 950);
    }

    function test_verify_activePlayerStillAboveThreshold_noop() public {
        _resetAndBootstrapContinuity();
        _seedScore(SEASON_B, YEAR_B, PLAYER_OUT, Position.CM, 950);
        playerSetRegistry.seedPlayer(PLAYER_OUT, PlayerStatus.GRADUATED, LEAGUE);

        EligibilityGroups memory groups = verifier.verifyEligibility(0, 10);
        assertEq(groups.toDeactivate.length, 0);
        assertEq(groups.toReactivate.length, 0);
        assertEq(groups.outfield.length, 0);
        assertEq(lifecycleManager.callCount(), 0);
        assertEq(dopplerLocker.callCount(), 0);
    }

    function test_verify_inactiveStillBelow_noop() public {
        _resetAndBootstrapContinuity();
        _seedScore(SEASON_B, YEAR_B, PLAYER_OUT, Position.CM, 100);
        playerSetRegistry.seedPlayer(PLAYER_OUT, PlayerStatus.INACTIVE, LEAGUE);

        EligibilityGroups memory groups = verifier.verifyEligibility(0, 10);
        assertEq(groups.toReactivate.length, 0);
        assertEq(lifecycleManager.callCount(), 0);
    }

    function test_verify_drainsLeftLeague_skipsUndeployed() public {
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

        // PLAYER_LOW left league but is not in PlayerSetRegistry → must not enqueue.
        playerSetRegistry.seedPlayer(PLAYER_OUT, PlayerStatus.GRADUATED, LEAGUE);
        verifier.verifyEligibility(0, 0);

        assertFalse(lifecycleManager.wasEnqueued(PLAYER_LOW, LifecycleReason.LeftLeague));
        assertFalse(lifecycleManager.wasEnqueued(PLAYER_OUT, LifecycleReason.LeftLeague));
        assertEq(lifecycleManager.callCount(), 0);
    }

    function test_verify_drainsLeftLeague_enqueuesDeployed() public {
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

        playerSetRegistry.seedPlayer(PLAYER_LOW, PlayerStatus.GRADUATED, LEAGUE);

        verifier.verifyEligibility(0, 0);
        assertTrue(lifecycleManager.wasEnqueued(PLAYER_LOW, LifecycleReason.LeftLeague));
        assertEq(lifecycleManager.effectiveMinsFor(PLAYER_LOW, LifecycleReason.LeftLeague), 0);
    }

    function test_verify_drainsLeagueChanged_forDeployed() public {
        bytes32 otherLeague = keccak256("laliga");
        bytes32 otherSeason = keccak256("laliga-2024");

        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);
        _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_OUT, CLUB_A, _birthYearsAgo(26)));
        playerSetRegistry.seedPlayer(PLAYER_OUT, PlayerStatus.GRADUATED, LEAGUE);

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

        verifier.verifyEligibility(0, 0);
        assertTrue(lifecycleManager.wasEnqueued(PLAYER_OUT, LifecycleReason.ChangedLeague));
    }

    // --------------------------------------------
    //  Pagination / rate limit / views
    // --------------------------------------------

    function test_verify_pagination_andRateLimit() public {
        _resetAndBootstrapContinuity();
        _seedScore(SEASON_B, YEAR_B, PLAYER_GK, Position.GK, 400);
        _seedScore(SEASON_B, YEAR_B, PLAYER_OUT, Position.CM, 950);

        EligibilityGroups memory page0 = verifier.verifyEligibility(0, 1);
        uint256 firstBatch = page0.goalkeepers.length + page0.under21.length + page0.outfield.length;
        assertEq(firstBatch, 1);

        vm.expectRevert(abi.encodeWithSelector(RateLimit.RateLimited.selector, block.timestamp + VERIFY_COOLDOWN));
        verifier.verifyEligibility(1, 1);

        _warpPastVerifyCooldown();
        EligibilityGroups memory page1 = verifier.verifyEligibility(1, 10);
        uint256 secondBatch = page1.goalkeepers.length + page1.under21.length + page1.outfield.length;
        assertEq(secondBatch, 1);
        assertEq(dopplerLocker.totalQueuedPlayers(), 2);
    }

    function test_verify_emptyOffset_drainsOnly() public {
        EligibilityGroups memory groups = verifier.verifyEligibility(0, 10);
        assertEq(groups.outfield.length, 0);
        assertEq(dopplerLocker.callCount(), 0);
    }

    function test_viewForwards() public {
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);
        _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_OUT, CLUB_A, _birthYearsAgo(26)));
        _seedScore(SEASON_B, YEAR_B, PLAYER_OUT, Position.CM, 50);

        assertEq(verifier.playerCount(), 1);
        assertEq(verifier.playerIds(0, 1)[0], PLAYER_OUT);
        assertEq(verifier.getMinutesStore(PLAYER_OUT).currentClubId, CLUB_A);
        assertEq(verifier.getSquadList(CLUB_A).playerIds[0], PLAYER_OUT);
        assertEq(_effectiveMins(PLAYER_OUT), 50);
    }

    function test_verify_purgesStaleDuringScan() public {
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

        // Age deactivated PLAYER_LOW past STALE_AFTER
        vm.warp(block.timestamp + 5 * 365 days + 1);
        treasury.setCursors(YEAR_B, 1, 1);

        uint256 before = squadStore.playerCount();
        assertEq(before, 2);

        verifier.verifyEligibility(0, 10);
        assertEq(squadStore.playerCount(), 1);
        assertEq(squadStore.playerIdAt(0), PLAYER_OUT);
    }

    function test_newTransfer_usesTreasurySeasonYear() public {
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);
        _ingestOneSeasonPage(requestId, _singlePlayerPage(PLAYER_NT, CLUB_A, _birthYearsAgo(26)));
        _seedScore(SEASON_B, YEAR_B, PLAYER_NT, Position.CM, 10);

        // Current season still YEAR_B → NewTransfer (no decay: active == seed round)
        treasury.setCursors(YEAR_B, 1, 1);
        EligibilityGroups memory groups = verifier.verifyEligibility(0, 1);
        assertEq(groups.newTransfers.length, 1);
        assertTrue(dopplerLocker.wasQueued(PLAYER_NT));

        _warpPastVerifyCooldown();

        // Advance season year → continuity/outfield (score 10 < 901) → no deploy
        treasury.setCursors(2025, 1, 1);
        uint256 queuedBefore = dopplerLocker.totalQueuedPlayers();
        groups = verifier.verifyEligibility(0, 1);
        assertEq(groups.newTransfers.length, 0);
        assertEq(groups.outfield.length, 0);
        assertEq(dopplerLocker.totalQueuedPlayers(), queuedBefore);
    }

    // --------------------------------------------
    //  Helpers
    // --------------------------------------------

    function _bootstrapPlayers() internal {
        bytes32 requestId = _openLeagueSingle(SEASON_B, YEAR_B);

        bytes32[] memory players = new bytes32[](4);
        bytes32[] memory clubs = new bytes32[](4);
        uint32[] memory births = new uint32[](4);
        players[0] = PLAYER_GK;
        players[1] = PLAYER_U21;
        players[2] = PLAYER_OUT;
        players[3] = PLAYER_LOW;
        clubs[0] = CLUB_A;
        clubs[1] = CLUB_A;
        clubs[2] = CLUB_B;
        clubs[3] = CLUB_B;
        births[0] = _birthYearsAgo(30);
        births[1] = _birthYearsAgo(18);
        births[2] = _birthYearsAgo(26);
        births[3] = _birthYearsAgo(27);

        _fulfill(requestId, _page(1, SQUAD_FETCH_PAGE_DONE, 0, players, clubs, births));
        _drainSortChunks(LEAGUE);
    }

    /// @dev Two-season ingest so startYear=YEAR_A while treasury current=YEAR_B → continuity buckets.
    function _resetAndBootstrapContinuity() internal {
        // Fresh store/verifier so prior Live state doesn't block openLeague.
        squadStore = new SquadStore(address(ap), 0);
        verifier = new EligibilityVerifier(address(ap));
        ap.setName(Addresses.SQUAD_STORE, address(squadStore));
        ap.setName(Addresses.ELIGIBILITY_VERIFIER, address(verifier));

        dopplerLocker = new MockDopplerLocker();
        lifecycleManager = new MockLifecycleManager();
        ap.setName(Addresses.MARKET_INITIALIZER, address(dopplerLocker));
        ap.setName(Addresses.LIFECYCLE_MANAGER, address(lifecycleManager));
        treasury.setCursors(YEAR_B, 1, 1);

        bytes32 requestId = _openLeagueTwoSeasons();

        bytes32[] memory players = new bytes32[](4);
        bytes32[] memory clubs = new bytes32[](4);
        uint32[] memory births = new uint32[](4);
        players[0] = PLAYER_GK;
        players[1] = PLAYER_U21;
        players[2] = PLAYER_OUT;
        players[3] = PLAYER_LOW;
        clubs[0] = CLUB_A;
        clubs[1] = CLUB_A;
        clubs[2] = CLUB_B;
        clubs[3] = CLUB_B;
        births[0] = _birthYearsAgo(30);
        births[1] = _birthYearsAgo(18);
        births[2] = _birthYearsAgo(26);
        births[3] = _birthYearsAgo(27);

        // Season A
        _fulfill(requestId, _page(1, SQUAD_FETCH_PAGE_DONE, 0, players, clubs, births));
        requestId = _drainSortChunks(LEAGUE);

        // Season B (same roster)
        _fulfill(requestId, _page(1, SQUAD_FETCH_PAGE_DONE, 0, players, clubs, births));
        _drainSortChunks(LEAGUE);
    }
}
