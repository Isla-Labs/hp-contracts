// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { AddressProvider } from "@src/AddressProvider.sol";
import { AddressKeys as Addresses } from "@addresses/AddressKeys.sol";
import { EligibilityVerifier } from "@src/data/eligibility/EligibilityVerifier.sol";
import { SquadStore } from "@src/data/eligibility/SquadStore.sol";
import { Orchestrator } from "@src/Orchestrator.sol";
import { Appearance } from "@types/data/PbrHistoricalTypes.sol";
import { RoundFetchPhase } from "@types/data/RoundManagerTypes.sol";
import {
    LeagueSquadFetch,
    SCORE_WAD,
    SeasonSquadStep,
    SquadFetchPage,
    SquadFetchPhase,
    SQUAD_FETCH_PAGE_DONE
} from "@types/data/SquadStoreTypes.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";
import { Position } from "@types/registries/PlayerSetTypes.sol";

import { MockCvmRouter } from "./mocks/MockCvmRouter.sol";
import { MockDopplerLocker } from "./mocks/MockDopplerLocker.sol";
import { MockLifecycleManager } from "./mocks/MockLifecycleManager.sol";
import { MockPbrHistorical } from "./mocks/MockPbrHistorical.sol";
import { MockPbrTreasury } from "./mocks/MockPbrTreasury.sol";
import { MockPlayerSetRegistry } from "./mocks/MockPlayerSetRegistry.sol";
import { MockRoundManager } from "./mocks/MockRoundManager.sol";
import { MockTournamentRegistry } from "./mocks/MockTournamentRegistry.sol";

abstract contract EligibilityTestBase is Test {
    bytes32 internal constant LEAGUE = keccak256("epl");
    bytes32 internal constant SEASON_A = keccak256("season-2023");
    bytes32 internal constant SEASON_B = keccak256("season-2024");
    bytes32 internal constant CLUB_A = keccak256("club-a");
    bytes32 internal constant CLUB_B = keccak256("club-b");

    bytes32 internal constant PLAYER_GK = keccak256("player-gk");
    bytes32 internal constant PLAYER_U21 = keccak256("player-u21");
    bytes32 internal constant PLAYER_OUT = keccak256("player-out");
    bytes32 internal constant PLAYER_NT = keccak256("player-nt");
    bytes32 internal constant PLAYER_LOW = keccak256("player-low");

    uint16 internal constant YEAR_A = 2023;
    uint16 internal constant YEAR_B = 2024;
    uint256 internal constant VERIFY_COOLDOWN = 1 hours;

    address internal orchestrator;
    address internal timelock = makeAddr("timelock");
    address internal pbrHistoricalAddr;

    AddressProvider internal ap;
    Orchestrator internal orch;
    MockCvmRouter internal cvmRouter;
    MockTournamentRegistry internal tournamentRegistry;
    MockPlayerSetRegistry internal playerSetRegistry;
    MockRoundManager internal roundManager;
    MockPbrHistorical internal pbrHistorical;
    MockPbrTreasury internal treasury;
    MockDopplerLocker internal dopplerLocker;
    MockLifecycleManager internal lifecycleManager;

    SquadStore internal squadStore;
    EligibilityVerifier internal verifier;

    function setUp() public virtual {
        // Realistic wall-clock so uint32 birthdates stay valid.
        vm.warp(1_700_000_000);

        ap = new AddressProvider(address(this));
        cvmRouter = new MockCvmRouter();
        ap.setName(Addresses.CVM_ROUTER, address(cvmRouter));

        tournamentRegistry = new MockTournamentRegistry();
        playerSetRegistry = new MockPlayerSetRegistry();
        roundManager = new MockRoundManager();
        pbrHistorical = new MockPbrHistorical();
        treasury = new MockPbrTreasury();
        dopplerLocker = new MockDopplerLocker();
        lifecycleManager = new MockLifecycleManager();
        pbrHistoricalAddr = address(pbrHistorical);

        orch = new Orchestrator(address(ap), VERIFY_COOLDOWN);
        orchestrator = address(orch);
        ap.setName(Addresses.ORCHESTRATOR, orchestrator);
        ap.setName(Addresses.HP_MULTISIG, address(this));
        ap.setName(Addresses.TIMELOCK, timelock);
        ap.setName(Addresses.TOURNAMENT_REGISTRY, address(tournamentRegistry));
        ap.setName(Addresses.PLAYER_SET_REGISTRY, address(playerSetRegistry));
        ap.setName(Addresses.ROUND_MANAGER, address(roundManager));
        ap.setName(Addresses.PBR_HISTORICAL, pbrHistoricalAddr);
        ap.setName(Addresses.MARKET_INITIALIZER, address(dopplerLocker));
        ap.setName(Addresses.LIFECYCLE_MANAGER, address(lifecycleManager));

        squadStore = new SquadStore(address(ap), 0);
        verifier = new EligibilityVerifier(address(ap));

        ap.setName(Addresses.SQUAD_STORE, address(squadStore));
        ap.setName(Addresses.ELIGIBILITY_VERIFIER, address(verifier));

        tournamentRegistry.setPbrTreasury(LEAGUE, address(treasury));
        tournamentRegistry.setSeasonId(LEAGUE, YEAR_A, SEASON_A);
        tournamentRegistry.setSeasonId(LEAGUE, YEAR_B, SEASON_B);
        tournamentRegistry.setFinalRound(LEAGUE, YEAR_A, 38);
        tournamentRegistry.setFinalRound(LEAGUE, YEAR_B, 38);
        // Keep active == appearance round used by `_seedScore` so verify sync does not decay under threshold.
        treasury.setCursors(YEAR_B, 1, 1);
    }

    // --------------------------------------------
    //  Bootstrap helpers
    // --------------------------------------------

    function _openLeagueSingle(bytes32 seasonId, uint16 year) internal returns (bytes32 requestId) {
        bytes32[] memory seasons = new bytes32[](1);
        seasons[0] = seasonId;
        uint16[] memory years_ = new uint16[](1);
        years_[0] = year;

        vm.prank(orchestrator);
        requestId = squadStore.openLeague(LEAGUE, seasons, years_);
    }

    function _openLeagueTwoSeasons() internal returns (bytes32 requestId) {
        bytes32[] memory seasons = new bytes32[](2);
        seasons[0] = SEASON_B; // intentionally reversed — store sorts ascending
        seasons[1] = SEASON_A;
        uint16[] memory years_ = new uint16[](2);
        years_[0] = YEAR_B;
        years_[1] = YEAR_A;

        vm.prank(orchestrator);
        requestId = squadStore.openLeague(LEAGUE, seasons, years_);
    }

    function _page(
        uint16 pageFetched,
        uint16 nextPage,
        uint16 personsOffset,
        bytes32[] memory playerIds,
        bytes32[] memory clubIds,
        uint32[] memory birthDates
    ) internal pure returns (bytes memory) {
        return abi.encode(
            SquadFetchPage({
                pageFetched: pageFetched,
                nextPage: nextPage,
                personsOffset: personsOffset,
                playerIds: playerIds,
                clubIds: clubIds,
                birthDates: birthDates
            })
        );
    }

    function _singlePlayerPage(
        bytes32 playerId,
        bytes32 clubId,
        uint32 birthDate
    ) internal pure returns (bytes memory) {
        bytes32[] memory playerIds = new bytes32[](1);
        bytes32[] memory clubIds = new bytes32[](1);
        uint32[] memory birthDates = new uint32[](1);
        playerIds[0] = playerId;
        clubIds[0] = clubId;
        birthDates[0] = birthDate;
        return _page(1, SQUAD_FETCH_PAGE_DONE, 0, playerIds, clubIds, birthDates);
    }

    function _fulfill(bytes32 requestId, bytes memory response) internal {
        cvmRouter.fulfill(requestId, response, "");
    }

    function _fulfillAck(bytes32 requestId) internal {
        cvmRouter.fulfill(requestId, bytes(""), "");
    }

    /**
     * @dev Fulfill one FetchPages response, then ack SortChunks until the machine leaves SortChunks
     *      (next season FetchPages, more fetch pages, or Live with no pending).
     * @return nextRequestId Pending request id (0 if idle / Live).
     */
    function _ingestOneSeasonPage(
        bytes32 leagueId,
        bytes32 requestId,
        bytes memory fetchPage
    ) internal returns (bytes32 nextRequestId) {
        _fulfill(requestId, fetchPage);
        return _drainSortChunks(leagueId);
    }

    function _ingestOneSeasonPage(bytes32 requestId, bytes memory fetchPage) internal returns (bytes32 nextRequestId) {
        return _ingestOneSeasonPage(LEAGUE, requestId, fetchPage);
    }

    /// @dev Ack SortChunks requests until step is FetchPages or there is no pending request.
    function _drainSortChunks(bytes32 leagueId) internal returns (bytes32 nextRequestId) {
        while (true) {
            LeagueSquadFetch memory fetch = squadStore.getFetchState(leagueId);
            nextRequestId = fetch.pendingRequestId;
            if (nextRequestId == bytes32(0)) return bytes32(0);
            if (fetch.step != SeasonSquadStep.SortChunks) return nextRequestId;
            _fulfillAck(nextRequestId);
        }
    }

    function _birthYearsAgo(uint256 yearsAgo) internal view returns (uint32) {
        return uint32(block.timestamp - yearsAgo * 365 days);
    }

    function _recordAppearance(
        bytes32 seasonId,
        uint16 year,
        bytes32 playerId,
        uint32 roundNumber,
        Position position,
        uint32 mins
    ) internal {
        Appearance[] memory apps = new Appearance[](1);
        apps[0] = Appearance({
            fixtureId: keccak256(abi.encode(playerId, roundNumber)),
            playerId: playerId,
            roundNumber: roundNumber,
            position: position,
            minsPlayed: mins
        });
        vm.prank(pbrHistoricalAddr);
        squadStore.recordAppearances(seasonId, year, apps);
    }

    /// @dev Seed weighted score by recording mins at round 1 (no prior decay).
    function _seedScore(bytes32 seasonId, uint16 year, bytes32 playerId, Position position, uint32 mins) internal {
        _recordAppearance(seasonId, year, playerId, 1, position, mins);
    }

    function _assertPhase(SquadFetchPhase expected) internal view {
        assertEq(uint8(squadStore.getFetchPhase(LEAGUE)), uint8(expected));
    }

    function _assertStep(SeasonSquadStep expected) internal view {
        assertEq(uint8(squadStore.getFetchState(LEAGUE).step), uint8(expected));
    }

    function _effectiveMins(bytes32 playerId) internal view returns (uint32) {
        return uint32(verifier.getVerifySnapshot(playerId).currentLeague.weightedScoreWad / SCORE_WAD);
    }

    function _warpPastVerifyCooldown() internal {
        vm.warp(block.timestamp + VERIFY_COOLDOWN + 1);
    }

    function _pendingJob(bytes32 requestId) internal view returns (CvmJob job) {
        (, job,) = cvmRouter.getPending(requestId);
    }

    function _setRoundManagerLive() internal {
        roundManager.setFetchPhase(LEAGUE, RoundFetchPhase.Live);
    }
}
