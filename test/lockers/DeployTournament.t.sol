// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DeploymentsErrors as Errors } from "@errors/lockers/DeploymentsErrors.sol";
import {
    BootstrapParams,
    BootstrapSeason,
    DeployParams,
    DeployResult,
    TournamentType
} from "@types/registries/TournamentTypes.sol";
import { DeployTournament } from "@src/lockers/tournaments/DeployTournament.sol";
import { MockPbrFeeHub } from "./mocks/MockPbrFactories.sol";

import { LockersTestBase } from "./LockersTestBase.sol";

contract DeployTournamentTest is LockersTestBase {
    function test_initialize_setsFactories() public view {
        assertEq(deployTournament.owner(), address(orch));
        assertTrue(deployTournament.factoriesConfigured());
        assertEq(address(deployTournament.pbrTreasuryFactory()), address(treasuryFactory));
        assertEq(address(deployTournament.pbrFeeHubFactory()), address(hubFactory));
    }

    function test_deploy_domesticLeague() public {
        DeployParams memory params = _leagueParams(LEAGUE, SEASON);

        bytes memory ret = _ownerCall(address(deployTournament), abi.encodeCall(DeployTournament.deploy, (params)));
        DeployResult memory result = abi.decode(ret, (DeployResult));

        assertTrue(result.pbrTreasury != address(0));
        assertTrue(result.pbrFeeHub != address(0));
        assertEq(treasuryFactory.createCount(), 1);
        assertEq(hubFactory.createCount(), 1);
        assertEq(tournamentRegistry.registerHubCount(), 1);
        assertEq(tournamentRegistry.createTournamentCount(), 1);
        assertEq(tournamentRegistry.openSeasonCount(), 1);
        assertEq(tournamentRegistry.lastCreatedTournamentId(), LEAGUE);
        assertEq(uint8(tournamentRegistry.lastCreatedType()), uint8(TournamentType.DOMESTIC_LEAGUE));
        assertEq(tournamentRegistry.tournamentIdOfSeason(SEASON), LEAGUE);
        assertEq(tournamentRegistry.pbrFeeHubOf(LEAGUE), result.pbrFeeHub);
    }

    function test_deploy_revertsAlreadySet() public {
        DeployParams memory params = _leagueParams(LEAGUE, SEASON);
        _ownerCall(address(deployTournament), abi.encodeCall(DeployTournament.deploy, (params)));

        vm.expectRevert(Errors.AlreadySet.selector);
        _ownerCall(address(deployTournament), abi.encodeCall(DeployTournament.deploy, (params)));
    }

    function test_deploy_revertsZeroId() public {
        DeployParams memory params = _leagueParams(bytes32(0), SEASON);
        vm.expectRevert(Errors.ZeroId.selector);
        _ownerCall(address(deployTournament), abi.encodeCall(DeployTournament.deploy, (params)));
    }

    function test_deploy_revertsZeroSeason() public {
        DeployParams memory params = _leagueParams(LEAGUE, SEASON);
        params.bootstrap.initialSeason = 0;
        vm.expectRevert(Errors.ZeroSeason.selector);
        _ownerCall(address(deployTournament), abi.encodeCall(DeployTournament.deploy, (params)));
    }

    function test_deploy_revertsZeroSalt() public {
        DeployParams memory params = _leagueParams(LEAGUE, SEASON);
        params.bootstrap.treasurySalt = bytes32(0);
        vm.expectRevert(Errors.ZeroSalt.selector);
        _ownerCall(address(deployTournament), abi.encodeCall(DeployTournament.deploy, (params)));
    }

    function test_deploy_revertsUnauthorized() public {
        DeployParams memory params = _leagueParams(LEAGUE, SEASON);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        deployTournament.deploy(params);
    }

    function test_simulateDeploy_cup_requiresHub() public {
        DeployParams memory params;
        params.tournamentType = TournamentType.DOMESTIC_CUP;
        params.bootstrap = BootstrapParams({
            tournamentId: keccak256("cup-1"),
            initialSeason: 2025,
            treasurySalt: bytes32(uint256(2)),
            seasons: new BootstrapSeason[](0)
        });
        params.leagueIds = new bytes32[](1);
        params.leagueIds[0] = LEAGUE;

        vm.expectRevert(abi.encodeWithSelector(Errors.HubNotRegistered.selector, LEAGUE));
        deployTournament.simulateDeploy(params);

        // Register hub then simulate succeeds.
        tournamentRegistry.addDomesticHub(LEAGUE, makeAddr("hub"));
        deployTournament.simulateDeploy(params);
    }

    function test_deploy_domesticCup_appendsTreasury() public {
        // First create a league hub.
        address leagueHub = address(new MockPbrFeeHub());
        tournamentRegistry.addDomesticHub(LEAGUE, leagueHub);

        DeployParams memory params;
        params.tournamentType = TournamentType.DOMESTIC_CUP;
        params.bootstrap = BootstrapParams({
            tournamentId: keccak256("cup-1"),
            initialSeason: 2025,
            treasurySalt: bytes32(uint256(3)),
            seasons: new BootstrapSeason[](0)
        });
        params.leagueIds = new bytes32[](1);
        params.leagueIds[0] = LEAGUE;

        bytes memory ret = _ownerCall(address(deployTournament), abi.encodeCall(DeployTournament.deploy, (params)));
        DeployResult memory result = abi.decode(ret, (DeployResult));

        assertTrue(result.pbrTreasury != address(0));
        assertEq(result.pbrFeeHub, address(0));
        assertEq(uint8(tournamentRegistry.lastCreatedType()), uint8(TournamentType.DOMESTIC_CUP));

        address[] memory cups = MockPbrFeeHub(leagueHub).getDomesticCups();
        assertEq(cups.length, 1);
        assertEq(cups[0], result.pbrTreasury);
    }

    function test_deploy_withoutAuthorizedContract_failsNestedExec() public {
        // Fresh DeployTournament that is NOT AUTHORIZED_CONTRACT — nested _exec fails.
        DeployTournament unauthorized = _deployDeployTournament();
        DeployParams memory params = _leagueParams(keccak256("league-x"), keccak256("season-x"));

        vm.expectRevert();
        _ownerCall(address(unauthorized), abi.encodeCall(DeployTournament.deploy, (params)));
    }

    function _leagueParams(bytes32 leagueId, bytes32 seasonId) internal pure returns (DeployParams memory params) {
        BootstrapSeason[] memory seasons = new BootstrapSeason[](1);
        seasons[0] = BootstrapSeason({ seasonId: seasonId, seasonStartYear: 2025, finalRound: 38 });

        params.tournamentType = TournamentType.DOMESTIC_LEAGUE;
        params.bootstrap = BootstrapParams({
            tournamentId: leagueId, initialSeason: 2025, treasurySalt: bytes32(uint256(1)), seasons: seasons
        });
        params.leagueIds = new bytes32[](0);
    }
}
