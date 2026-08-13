// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { AddressProvider } from "@src/AddressProvider.sol";
import { AddressKeys as Addresses } from "@addresses/AddressKeys.sol";
import { RoundManager } from "@src/data/matchweeks/RoundManager.sol";
import { LiveRoundSyncKind, RoundFetchPhase, SeasonFetchStep } from "@types/data/RoundManagerTypes.sol";
import { SquadFetchPhase } from "@types/data/SquadStoreTypes.sol";
import { RoundSchedule, TournamentType } from "@types/registries/TournamentTypes.sol";

import { MockCvmRouter } from "./mocks/MockCvmRouter.sol";
import { MockPbrHistorical } from "./mocks/MockPbrHistorical.sol";
import { MockSquadStore } from "./mocks/MockSquadStore.sol";
import { MockTournamentInitializer } from "./mocks/MockTournamentInitializer.sol";
import { MockTournamentRegistry } from "./mocks/MockTournamentRegistry.sol";

abstract contract RoundManagerTestBase is Test {
    bytes32 internal constant TOURNAMENT = keccak256("tournament-1");
    bytes32 internal constant SEASON_A = keccak256("season-2023");
    bytes32 internal constant SEASON_B = keccak256("season-2024");
    bytes32 internal constant SEASON_C = keccak256("season-2025");

    uint16 internal constant YEAR_A = 2023;
    uint16 internal constant YEAR_B = 2024;
    uint16 internal constant YEAR_C = 2025;

    /// @dev Short season: 1 Format + 2 Upsert pages (cursor 1 then 11).
    uint32 internal constant FINAL_ROUND = 12;

    uint256 internal constant REFRESH_COOLDOWN = 1 hours;

    address internal orchestrator = makeAddr("orchestrator");

    AddressProvider internal ap;
    MockCvmRouter internal cvmRouter;
    MockTournamentRegistry internal tournamentRegistry;
    MockTournamentInitializer internal tournamentInitializer;
    MockSquadStore internal squadStore;
    MockPbrHistorical internal pbrHistorical;
    RoundManager internal roundManager;

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        ap = new AddressProvider(address(this));
        cvmRouter = new MockCvmRouter();
        ap.setName(Addresses.CVM_ROUTER, address(cvmRouter));

        tournamentRegistry = new MockTournamentRegistry();
        tournamentInitializer = new MockTournamentInitializer();
        squadStore = new MockSquadStore();
        pbrHistorical = new MockPbrHistorical();

        ap.setName(Addresses.ORCHESTRATOR, orchestrator);
        ap.setName(Addresses.TOURNAMENT_REGISTRY, address(tournamentRegistry));
        ap.setName(Addresses.TOURNAMENT_INITIALIZER, address(tournamentInitializer));
        ap.setName(Addresses.SQUAD_STORE, address(squadStore));
        ap.setName(Addresses.PBR_HISTORICAL, address(pbrHistorical));

        roundManager = new RoundManager(address(ap), REFRESH_COOLDOWN);
        ap.setName(Addresses.ROUND_MANAGER, address(roundManager));

        tournamentRegistry.setTournamentType(TOURNAMENT, TournamentType.DOMESTIC_LEAGUE);
        _seedFinalRound(TOURNAMENT, YEAR_A, FINAL_ROUND);
        _seedFinalRound(TOURNAMENT, YEAR_B, FINAL_ROUND);
    }

    // --------------------------------------------
    //  Orchestrator helpers
    // --------------------------------------------

    function _openTournament(
        bytes32 tournamentId,
        bytes32[] memory seasonIds,
        uint16[] memory seasonYears
    ) internal returns (bytes32 requestId) {
        vm.prank(orchestrator);
        return roundManager.openTournament(tournamentId, seasonIds, seasonYears);
    }

    function _openSingleSeason(bytes32 tournamentId, bytes32 seasonId, uint16 year) internal returns (bytes32) {
        bytes32[] memory seasonIds = new bytes32[](1);
        seasonIds[0] = seasonId;
        uint16[] memory seasonYears = new uint16[](1);
        seasonYears[0] = year;
        return _openTournament(tournamentId, seasonIds, seasonYears);
    }

    function _upsertRound(bytes32 tournamentId, uint16 year, RoundSchedule memory round) internal {
        vm.prank(orchestrator);
        roundManager.upsertRound(tournamentId, year, round);
    }

    function _upsertRounds(bytes32 tournamentId, uint16 year, RoundSchedule[] memory rounds) internal {
        vm.prank(orchestrator);
        roundManager.upsertRounds(tournamentId, year, rounds);
    }

    // --------------------------------------------
    //  Schedule builders
    // --------------------------------------------

    function _formatRounds(uint32 n) internal pure returns (RoundSchedule[] memory rounds) {
        rounds = new RoundSchedule[](n);
        for (uint32 i; i < n; ++i) {
            rounds[i] = RoundSchedule({
                roundNumber: i + 1,
                startTime: uint64(1_700_000_000 + uint256(i) * 1 weeks),
                endTime: uint64(1_700_000_000 + uint256(i) * 1 weeks + 3 days),
                fixtureIds: new bytes32[](0)
            });
        }
    }

    function _formatRoundsWithFixtures(
        uint32 n,
        uint256 fixturesPerRound
    ) internal pure returns (RoundSchedule[] memory rounds) {
        rounds = _formatRounds(n);
        for (uint32 i; i < n; ++i) {
            bytes32[] memory fixtures = new bytes32[](fixturesPerRound);
            for (uint256 j; j < fixturesPerRound; ++j) {
                fixtures[j] = keccak256(abi.encode("fmt-fixture", i + 1, j));
            }
            rounds[i].fixtureIds = fixtures;
        }
    }

    function _fixturePage(
        uint32 startRound,
        uint32 count,
        uint256 fixturesPerRound
    ) internal pure returns (RoundSchedule[] memory rounds) {
        rounds = new RoundSchedule[](count);
        for (uint32 i; i < count; ++i) {
            uint32 roundNumber = startRound + i;
            bytes32[] memory fixtures = new bytes32[](fixturesPerRound);
            for (uint256 j; j < fixturesPerRound; ++j) {
                fixtures[j] = keccak256(abi.encode("fixture", roundNumber, j));
            }
            rounds[i] = RoundSchedule({
                roundNumber: roundNumber,
                startTime: uint64(1_700_000_000 + uint256(roundNumber) * 1 weeks),
                endTime: uint64(1_700_000_000 + uint256(roundNumber) * 1 weeks + 3 days),
                fixtureIds: fixtures
            });
        }
    }

    // --------------------------------------------
    //  Oracle fulfill helpers
    // --------------------------------------------

    function _fulfillHistorical(bytes32 requestId, RoundSchedule[] memory rounds) internal {
        cvmRouter.fulfill(requestId, abi.encode(rounds), "");
    }

    function _fulfillHistoricalErr(bytes32 requestId, bytes memory err) internal {
        cvmRouter.fulfill(requestId, "", err);
    }

    function _fulfillLiveRefresh(bytes32 requestId, RoundSchedule[] memory rounds) internal {
        bytes memory payload = abi.encode(rounds);
        cvmRouter.fulfill(requestId, abi.encode(uint8(LiveRoundSyncKind.Refresh), payload), "");
    }

    function _fulfillLiveOpenSeason(bytes32 requestId, bytes32 seasonId, uint16 year, uint32 finalRound) internal {
        bytes memory payload = abi.encode(seasonId, year, finalRound);
        cvmRouter.fulfill(requestId, abi.encode(uint8(LiveRoundSyncKind.OpenSeason), payload), "");
    }

    function _seedFinalRound(bytes32 tournamentId, uint16 year, uint32 finalRound) internal {
        tournamentRegistry.setFinalRound(tournamentId, year, finalRound);
    }

    /// @dev Drain one season's Format + Upsert pages for `FINAL_ROUND` (12).
    function _drainSeasonHistorical(uint16 year) internal {
        bytes32 requestId = cvmRouter.lastRequestId();
        _fulfillHistorical(requestId, _formatRounds(FINAL_ROUND));

        // page 1: rounds 1-10
        requestId = cvmRouter.lastRequestId();
        _fulfillHistorical(requestId, _fixturePage(1, 10, 2));

        // page 2: rounds 11-12
        requestId = cvmRouter.lastRequestId();
        _fulfillHistorical(requestId, _fixturePage(11, 2, 2));

        // silence unused year param in signature for multi-season clarity
        year;
    }

    function _drainHistoricalToLive(
        bytes32 tournamentId,
        bytes32[] memory seasonIds,
        uint16[] memory seasonYears
    ) internal {
        // RoundManager sorts ascending by year — drain in the same order.
        uint256 length = seasonYears.length;
        uint16[] memory orderedSeasonYears = new uint16[](length);
        for (uint256 i; i < length; ++i) {
            orderedSeasonYears[i] = seasonYears[i];
        }
        for (uint256 i = 1; i < length; ++i) {
            uint16 key = orderedSeasonYears[i];
            uint256 j = i;
            while (j > 0 && orderedSeasonYears[j - 1] > key) {
                orderedSeasonYears[j] = orderedSeasonYears[j - 1];
                unchecked {
                    --j;
                }
            }
            orderedSeasonYears[j] = key;
        }

        _openTournament(tournamentId, seasonIds, seasonYears);
        for (uint256 i; i < length; ++i) {
            _seedFinalRound(tournamentId, orderedSeasonYears[i], FINAL_ROUND);
            _drainSeasonHistorical(orderedSeasonYears[i]);
        }
        assertEq(uint8(roundManager.getFetchPhase(tournamentId)), uint8(RoundFetchPhase.Live));
    }

    function _drainSingleToLive(bytes32 tournamentId, bytes32 seasonId, uint16 year) internal {
        bytes32[] memory seasonIds = new bytes32[](1);
        seasonIds[0] = seasonId;
        uint16[] memory seasonYears = new uint16[](1);
        seasonYears[0] = year;
        squadStore.setFetchPhase(tournamentId, SquadFetchPhase.Live);
        _drainHistoricalToLive(tournamentId, seasonIds, seasonYears);
    }

    function _assertStep(bytes32 tournamentId, SeasonFetchStep step) internal view {
        assertEq(uint8(roundManager.getFetchState(tournamentId).step), uint8(step));
    }
}
