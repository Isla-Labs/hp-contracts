// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { MarketsErrors as Errors } from "@errors/markets/MarketsErrors.sol";
import { PbrFeeHub } from "@markets/PbrFeeHub.sol";

import { MarketsTestBase } from "./MarketsTestBase.sol";
import { AcceptingReceiver } from "./mocks/ETHReceivers.sol";

contract PbrFeeHubFactoryTest is MarketsTestBase {
    bytes32 internal constant LEAGUE_A = keccak256("league-a");
    bytes32 internal constant LEAGUE_B = keccak256("league-b");

    function test_constructor_setsBeaconOwnedByTimelock() public view {
        assertEq(pbrFeeHubFactory.beacon().owner(), timelock);
        assertTrue(pbrFeeHubFactory.implementation() != address(0));
    }

    function test_create_revertsUnauthorized() public {
        AcceptingReceiver treasury = new AcceptingReceiver();
        vm.expectRevert(Errors.Unauthorized.selector);
        pbrFeeHubFactory.create(LEAGUE_A, address(treasury));
    }

    function test_create_revertsZeroId() public {
        AcceptingReceiver treasury = new AcceptingReceiver();
        vm.prank(tournamentInitializer);
        vm.expectRevert(Errors.ZeroId.selector);
        pbrFeeHubFactory.create(bytes32(0), address(treasury));
    }

    function test_create_revertsZeroTreasury() public {
        vm.prank(tournamentInitializer);
        vm.expectRevert(Errors.ZeroAddress.selector);
        pbrFeeHubFactory.create(LEAGUE_A, address(0));
    }

    function test_create_setsDefaults() public {
        AcceptingReceiver treasury = new AcceptingReceiver();
        PbrFeeHub hub = _createPbrFeeHub(LEAGUE_A, address(treasury));

        assertEq(hub.leagueId(), LEAGUE_A);
        assertEq(hub.leagueTreasury(), address(treasury));
        assertEq(hub.domesticBps(), 9000);
        assertEq(hub.continentalBps(), 900);
        assertEq(hub.internationalBps(), 100);
        assertEq(hub.leagueShareBps(), 8900);
        assertEq(hub.internationalActiveShareBps(), 9000);
        assertFalse(hub.internationalActive());
        assertEq(hub.getDomesticCups().length, 0);
        assertEq(hub.getContinental().length, 0);
        assertEq(hub.getInternational().length, 0);
    }

    function test_create_notIdempotent() public {
        AcceptingReceiver treasury = new AcceptingReceiver();
        PbrFeeHub first = _createPbrFeeHub(LEAGUE_A, address(treasury));
        PbrFeeHub second = _createPbrFeeHub(LEAGUE_A, address(treasury));
        assertTrue(address(first) != address(second));
    }

    function test_create_distinctLeagues() public {
        AcceptingReceiver treasury = new AcceptingReceiver();
        PbrFeeHub a = _createPbrFeeHub(LEAGUE_A, address(treasury));
        PbrFeeHub b = _createPbrFeeHub(LEAGUE_B, address(treasury));
        assertTrue(address(a) != address(b));
        assertEq(a.leagueId(), LEAGUE_A);
        assertEq(b.leagueId(), LEAGUE_B);
    }
}
