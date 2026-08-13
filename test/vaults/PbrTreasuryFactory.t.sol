// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { VaultsErrors as Errors } from "@errors/vaults/VaultsErrors.sol";
import { PbrTreasury } from "@vaults/PbrTreasury.sol";

import { VaultsTestBase } from "./VaultsTestBase.sol";

contract PbrTreasuryFactoryTest is VaultsTestBase {
    function setUp() public override {
        super.setUp();
        _etchCreateX();
    }

    function test_constructor_setsTimelockOwnedBeacon() public view {
        assertEq(treasuryFactory.beacon().owner(), timelock);
        assertTrue(treasuryFactory.implementation() != address(0));
    }

    function test_create_revertsUnauthorized() public {
        bytes32 salt = _permissionedSalt(address(treasuryFactory), bytes11(uint88(1)));
        vm.expectRevert(Errors.Unauthorized.selector);
        treasuryFactory.create(TOURNAMENT, START_YEAR, salt);
    }

    function test_create_revertsZeroId() public {
        bytes32 salt = _permissionedSalt(address(treasuryFactory), bytes11(uint88(1)));
        vm.prank(tournamentInitializer);
        vm.expectRevert(Errors.ZeroId.selector);
        treasuryFactory.create(bytes32(0), START_YEAR, salt);
    }

    function test_create_revertsZeroSeason() public {
        bytes32 salt = _permissionedSalt(address(treasuryFactory), bytes11(uint88(1)));
        vm.prank(tournamentInitializer);
        vm.expectRevert(Errors.ZeroSeason.selector);
        treasuryFactory.create(TOURNAMENT, 0, salt);
    }

    function test_create_revertsZeroSalt() public {
        vm.prank(tournamentInitializer);
        vm.expectRevert(Errors.ZeroSalt.selector);
        treasuryFactory.create(TOURNAMENT, START_YEAR, bytes32(0));
    }

    function test_create_wiresTreasury() public {
        bytes32 salt = _permissionedSalt(address(treasuryFactory), bytes11(uint88(99)));
        address predicted = _predictCreate3(address(treasuryFactory), salt);

        vm.prank(tournamentInitializer);
        address treasuryAddr = treasuryFactory.create(TOURNAMENT, START_YEAR, salt);

        assertEq(treasuryAddr, predicted);

        PbrTreasury treasury = PbrTreasury(payable(treasuryAddr));
        assertEq(treasury.tournamentId(), TOURNAMENT);
        assertEq(treasury.seasonStartYear(), START_YEAR);
        assertEq(treasury.activeRound(), 1);
        assertEq(treasury.tradingRound(), 1);
    }
}
