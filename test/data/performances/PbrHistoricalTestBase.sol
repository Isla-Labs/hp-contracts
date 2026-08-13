// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { AddressProvider } from "@src/AddressProvider.sol";
import { AddressKeys as Addresses } from "@addresses/AddressKeys.sol";
import { PbrHistorical } from "@src/data/performances/PbrHistorical.sol";
import { Appearance } from "@types/data/PbrHistoricalTypes.sol";
import { SeasonRef } from "@types/data/RoundManagerTypes.sol";
import { Position } from "@types/registries/PlayerSetTypes.sol";
import { TournamentType } from "@types/registries/TournamentTypes.sol";

import { MockCvmRouter } from "./mocks/MockCvmRouter.sol";
import { MockRoundManager } from "./mocks/MockRoundManager.sol";
import { MockSquadStore } from "./mocks/MockSquadStore.sol";
import { MockTournamentRegistry } from "./mocks/MockTournamentRegistry.sol";

abstract contract PbrHistoricalTestBase is Test {
    bytes32 internal constant TOURNAMENT = keccak256("tournament-1");
    bytes32 internal constant SEASON_A = keccak256("season-2023");
    bytes32 internal constant SEASON_B = keccak256("season-2024");
    bytes32 internal constant FIXTURE_1 = keccak256("fixture-1");
    bytes32 internal constant FIXTURE_2 = keccak256("fixture-2");
    bytes32 internal constant FIXTURE_3 = keccak256("fixture-3");
    bytes32 internal constant PLAYER_A = keccak256("player-a");
    bytes32 internal constant PLAYER_B = keccak256("player-b");

    uint16 internal constant YEAR_A = 2023;
    uint16 internal constant YEAR_B = 2024;

    AddressProvider internal ap;
    MockCvmRouter internal cvmRouter;
    MockRoundManager internal roundManager;
    MockTournamentRegistry internal tournamentRegistry;
    MockSquadStore internal squadStore;
    PbrHistorical internal pbrHistorical;

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        ap = new AddressProvider(address(this));
        cvmRouter = new MockCvmRouter();
        ap.setName(Addresses.CVM_ROUTER, address(cvmRouter));

        roundManager = new MockRoundManager();
        tournamentRegistry = new MockTournamentRegistry();
        squadStore = new MockSquadStore();

        ap.setName(Addresses.ROUND_MANAGER, address(roundManager));
        ap.setName(Addresses.SQUAD_STORE, address(squadStore));
        ap.setName(Addresses.TOURNAMENT_REGISTRY, address(tournamentRegistry));

        pbrHistorical = new PbrHistorical(address(ap));
        ap.setName(Addresses.PBR_HISTORICAL, address(pbrHistorical));

        tournamentRegistry.setTournamentType(TOURNAMENT, TournamentType.DOMESTIC_LEAGUE);
    }

    // --------------------------------------------
    //  Seed helpers
    // --------------------------------------------

    function _seedSeasons(bytes32 tournamentId, SeasonRef[] memory seasons) internal {
        roundManager.setSeasons(tournamentId, seasons);
    }

    function _seedSingleSeason(bytes32 tournamentId, bytes32 seasonId, uint16 year, uint32 finalRound) internal {
        SeasonRef[] memory seasons = new SeasonRef[](1);
        seasons[0] = SeasonRef({ seasonId: seasonId, seasonStartYear: year });
        _seedSeasons(tournamentId, seasons);
        tournamentRegistry.setFinalRound(tournamentId, year, finalRound);
    }

    function _seedTwoSeasons(uint32 finalRound) internal {
        SeasonRef[] memory seasons = new SeasonRef[](2);
        seasons[0] = SeasonRef({ seasonId: SEASON_A, seasonStartYear: YEAR_A });
        seasons[1] = SeasonRef({ seasonId: SEASON_B, seasonStartYear: YEAR_B });
        _seedSeasons(TOURNAMENT, seasons);
        tournamentRegistry.setFinalRound(TOURNAMENT, YEAR_A, finalRound);
        tournamentRegistry.setFinalRound(TOURNAMENT, YEAR_B, finalRound);
    }

    function _setRoundFixtures(uint16 year, uint32 roundNumber, bytes32[] memory fixtures) internal {
        tournamentRegistry.setRound(TOURNAMENT, year, roundNumber, fixtures);
    }

    function _oneFixture(bytes32 fixtureId) internal pure returns (bytes32[] memory fixtures) {
        fixtures = new bytes32[](1);
        fixtures[0] = fixtureId;
    }

    function _twoFixtures(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory fixtures) {
        fixtures = new bytes32[](2);
        fixtures[0] = a;
        fixtures[1] = b;
    }

    // --------------------------------------------
    //  Open / fulfill helpers
    // --------------------------------------------

    function _openAsRoundManager(bytes32 tournamentId) internal returns (bytes32[] memory requestIds) {
        vm.prank(address(roundManager));
        return pbrHistorical.openHistorical(tournamentId);
    }

    function _openAsSquadStore(bytes32 tournamentId) internal returns (bytes32[] memory requestIds) {
        vm.prank(address(squadStore));
        return pbrHistorical.openHistorical(tournamentId);
    }

    function _appearance(
        bytes32 fixtureId,
        bytes32 playerId,
        uint32 roundNumber
    ) internal pure returns (Appearance memory) {
        return Appearance({
            fixtureId: fixtureId, playerId: playerId, roundNumber: roundNumber, position: Position.CM, minsPlayed: 90
        });
    }

    function _fulfillOk(
        bytes32 requestId,
        bytes32 fixtureId,
        bytes32 digest,
        Appearance[] memory appearances
    ) internal {
        cvmRouter.fulfill(requestId, abi.encode(fixtureId, digest, appearances), "");
    }

    function _fulfillOkSimple(bytes32 requestId, bytes32 fixtureId, uint32 roundNumber) internal {
        Appearance[] memory apps = new Appearance[](1);
        apps[0] = _appearance(fixtureId, PLAYER_A, roundNumber);
        _fulfillOk(requestId, fixtureId, keccak256(abi.encode(fixtureId, "rss")), apps);
    }

    function _fulfillErr(bytes32 requestId, bytes memory err) internal {
        cvmRouter.fulfill(requestId, "", err);
    }

    function _digest(bytes32 fixtureId) internal pure returns (bytes32) {
        return keccak256(abi.encode(fixtureId, "rss"));
    }

    /// @dev Open domestic tournament with finalRound=1, one fixture — returns the single request id.
    function _openSimpleRound() internal returns (bytes32 requestId) {
        _seedSingleSeason(TOURNAMENT, SEASON_A, YEAR_A, 1);
        _setRoundFixtures(YEAR_A, 1, _oneFixture(FIXTURE_1));
        bytes32[] memory ids = _openAsRoundManager(TOURNAMENT);
        assertEq(ids.length, 1);
        return ids[0];
    }
}
