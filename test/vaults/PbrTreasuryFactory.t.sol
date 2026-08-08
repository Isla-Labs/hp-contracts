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

    function test_initialize_setsOrchestratorAndBeacon() public view {
        assertEq(treasuryFactory.orchestrator(), orchestrator);
        assertEq(treasuryFactory.owner(), orchestrator);
        assertEq(treasuryFactory.beacon().owner(), orchestrator);
        assertTrue(treasuryFactory.implementation() != address(0));
    }

    function test_create_revertsUnauthorized() public {
        bytes32 salt = treasuryFactory.makeSalt(bytes11(uint88(1)));
        vm.expectRevert(Errors.Unauthorized.selector);
        treasuryFactory.create(TOURNAMENT, START_YEAR, salt);
    }

    function test_create_revertsZeroId() public {
        bytes32 salt = treasuryFactory.makeSalt(bytes11(uint88(1)));
        vm.prank(orchestrator);
        vm.expectRevert(Errors.ZeroId.selector);
        treasuryFactory.create(bytes32(0), START_YEAR, salt);
    }

    function test_create_revertsZeroSeason() public {
        bytes32 salt = treasuryFactory.makeSalt(bytes11(uint88(1)));
        vm.prank(orchestrator);
        vm.expectRevert(Errors.ZeroSeason.selector);
        treasuryFactory.create(TOURNAMENT, 0, salt);
    }

    function test_create_revertsZeroSalt() public {
        vm.prank(orchestrator);
        vm.expectRevert(Errors.ZeroSalt.selector);
        treasuryFactory.create(TOURNAMENT, START_YEAR, bytes32(0));
    }

    function test_create_wiresTreasury() public {
        bytes32 salt = treasuryFactory.makeSalt(bytes11(uint88(99)));
        address predicted = treasuryFactory.computeCreate3Address(salt);

        vm.prank(orchestrator);
        address treasuryAddr = treasuryFactory.create(TOURNAMENT, START_YEAR, salt);

        assertEq(treasuryAddr, predicted);

        PbrTreasury treasury = PbrTreasury(payable(treasuryAddr));
        assertEq(treasury.tournamentId(), TOURNAMENT);
        assertEq(treasury.seasonStartYear(), START_YEAR);
        assertEq(treasury.activeRound(), 1);
        assertEq(treasury.tradingRound(), 1);
        assertEq(treasury.owner(), orchestrator);
        assertEq(treasury.pbrSettle(), address(pbrSettle));
    }
}
