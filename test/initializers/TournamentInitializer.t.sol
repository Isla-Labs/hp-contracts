// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DeploymentsErrors as Errors } from "@errors/initializers/DeploymentsErrors.sol";
import {
    BootstrapParams,
    BootstrapSeason,
    CreateTournamentData,
    DeployParams,
    TournamentType
} from "@types/registries/TournamentTypes.sol";
import { TournamentInitializer } from "@src/initializers/tournaments/TournamentInitializer.sol";

import { InitializersTestBase } from "./InitializersTestBase.sol";
import { MockPbrFeeHub } from "./mocks/MockPbrFactories.sol";

contract TournamentInitializerTest is InitializersTestBase {
    function test_create_domesticLeague() public {
        DeployParams memory params = _leagueParams(LEAGUE, SEASON);

        bytes memory ret =
            _asOrch(address(tournamentInitializer), abi.encodeCall(TournamentInitializer.create, (params)));
        CreateTournamentData memory data = abi.decode(ret, (CreateTournamentData));

        assertTrue(data.pbrTreasury != address(0));
        assertTrue(data.pbrFeeHub != address(0));
        assertEq(data.tournamentId, LEAGUE);
        assertEq(uint8(data.tournamentType), uint8(TournamentType.DOMESTIC_LEAGUE));
        assertEq(treasuryFactory.createCount(), 1);
        assertEq(hubFactory.createCount(), 1);
        assertEq(tournamentRegistry.registerHubCount(), 1);
        assertEq(tournamentRegistry.createTournamentCount(), 1);
        assertEq(tournamentRegistry.openSeasonCount(), 1);
        assertEq(tournamentRegistry.lastCreatedTournamentId(), LEAGUE);
        assertEq(uint8(tournamentRegistry.lastCreatedType()), uint8(TournamentType.DOMESTIC_LEAGUE));
        assertEq(tournamentRegistry.tournamentIdOfSeason(SEASON), LEAGUE);
        assertEq(tournamentRegistry.pbrFeeHubOf(LEAGUE), data.pbrFeeHub);
        assertEq(data.seasonIds.length, 1);
        assertEq(data.seasonIds[0], SEASON);
    }

    function test_create_revertsAlreadyExists() public {
        DeployParams memory params = _leagueParams(LEAGUE, SEASON);
        _asOrch(address(tournamentInitializer), abi.encodeCall(TournamentInitializer.create, (params)));

        vm.expectRevert(abi.encodeWithSelector(Errors.TournamentsExist.selector, uint256(1)));
        _asOrch(address(tournamentInitializer), abi.encodeCall(TournamentInitializer.create, (params)));
    }

    function test_create_revertsZeroId() public {
        DeployParams memory params = _leagueParams(bytes32(0), SEASON);
        vm.expectRevert(Errors.ZeroId.selector);
        _asOrch(address(tournamentInitializer), abi.encodeCall(TournamentInitializer.create, (params)));
    }

    function test_create_revertsZeroSeason() public {
        DeployParams memory params = _leagueParams(LEAGUE, SEASON);
        params.bootstrap.initialSeasonStartYear = 0;
        vm.expectRevert(Errors.ZeroSeason.selector);
        _asOrch(address(tournamentInitializer), abi.encodeCall(TournamentInitializer.create, (params)));
    }

    function test_create_revertsZeroSalt() public {
        DeployParams memory params = _leagueParams(LEAGUE, SEASON);
        params.bootstrap.treasurySalt = bytes32(0);
        vm.expectRevert(Errors.ZeroSalt.selector);
        _asOrch(address(tournamentInitializer), abi.encodeCall(TournamentInitializer.create, (params)));
    }

    function test_create_revertsUnauthorized() public {
        DeployParams memory params = _leagueParams(LEAGUE, SEASON);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.Unauthorized.selector);
        tournamentInitializer.create(params);
    }

    function test_create_domesticCup_requiresHub() public {
        DeployParams memory params;
        params.tournamentType = TournamentType.DOMESTIC_CUP;
        params.bootstrap = BootstrapParams({
            tournamentId: keccak256("cup-1"),
            initialSeasonStartYear: 2025,
            treasurySalt: bytes32(uint256(2)),
            seasons: new BootstrapSeason[](0)
        });
        params.leagueIds = new bytes32[](1);
        params.leagueIds[0] = LEAGUE;

        vm.expectRevert(abi.encodeWithSelector(Errors.HubNotRegistered.selector, LEAGUE));
        _asOrch(address(tournamentInitializer), abi.encodeCall(TournamentInitializer.create, (params)));
    }

    function test_create_domesticCup_appendsTreasury() public {
        address leagueHub = address(new MockPbrFeeHub());
        tournamentRegistry.addDomesticHub(LEAGUE, leagueHub);

        DeployParams memory params;
        params.tournamentType = TournamentType.DOMESTIC_CUP;
        params.bootstrap = BootstrapParams({
            tournamentId: keccak256("cup-1"),
            initialSeasonStartYear: 2025,
            treasurySalt: bytes32(uint256(3)),
            seasons: new BootstrapSeason[](0)
        });
        params.leagueIds = new bytes32[](1);
        params.leagueIds[0] = LEAGUE;

        bytes memory ret =
            _asOrch(address(tournamentInitializer), abi.encodeCall(TournamentInitializer.create, (params)));
        CreateTournamentData memory data = abi.decode(ret, (CreateTournamentData));

        assertTrue(data.pbrTreasury != address(0));
        assertEq(data.pbrFeeHub, address(0));
        assertEq(uint8(tournamentRegistry.lastCreatedType()), uint8(TournamentType.DOMESTIC_CUP));

        address[] memory cups = MockPbrFeeHub(leagueHub).getDomesticCups();
        assertEq(cups.length, 1);
        assertEq(cups[0], data.pbrTreasury);
    }

    function _leagueParams(bytes32 leagueId, bytes32 seasonId) internal pure returns (DeployParams memory params) {
        BootstrapSeason[] memory seasons = new BootstrapSeason[](1);
        seasons[0] = BootstrapSeason({ seasonId: seasonId, seasonStartYear: 2025, finalRound: 38 });

        params.tournamentType = TournamentType.DOMESTIC_LEAGUE;
        params.bootstrap = BootstrapParams({
            tournamentId: leagueId, initialSeasonStartYear: 2025, treasurySalt: bytes32(uint256(1)), seasons: seasons
        });
        params.leagueIds = new bytes32[](0);
    }
}
