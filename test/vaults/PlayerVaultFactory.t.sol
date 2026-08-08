// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { VaultsErrors as Errors } from "@errors/vaults/VaultsErrors.sol";
import { PlayerVault } from "@vaults/PlayerVault.sol";
import { StakedToken } from "@vaults/StakedToken.sol";

import { VaultsTestBase } from "./VaultsTestBase.sol";

contract PlayerVaultFactoryTest is VaultsTestBase {
    function setUp() public override {
        super.setUp();
        _etchCreateX();
    }

    function test_initialize_setsOrchestratorAndBeacon() public view {
        assertEq(vaultFactory.orchestrator(), orchestrator);
        assertEq(vaultFactory.owner(), orchestrator);
        assertEq(vaultFactory.beacon().owner(), orchestrator);
        assertTrue(vaultFactory.implementation() != address(0));
    }

    function test_create_revertsUnauthorized() public {
        bytes32 vaultSalt = vaultFactory.makeSalt(bytes11(uint88(1)));
        bytes32 stSalt = vaultFactory.makeSalt(bytes11(uint88(2)));
        vm.expectRevert(Errors.Unauthorized.selector);
        vaultFactory.create(PLAYER, address(playerToken), "Player", "PLY", vaultSalt, stSalt);
    }

    function test_create_revertsZeroId() public {
        bytes32 vaultSalt = vaultFactory.makeSalt(bytes11(uint88(1)));
        bytes32 stSalt = vaultFactory.makeSalt(bytes11(uint88(2)));
        vm.prank(orchestrator);
        vm.expectRevert(Errors.ZeroId.selector);
        vaultFactory.create(bytes32(0), address(playerToken), "Player", "PLY", vaultSalt, stSalt);
    }

    function test_create_revertsZeroToken() public {
        bytes32 vaultSalt = vaultFactory.makeSalt(bytes11(uint88(1)));
        bytes32 stSalt = vaultFactory.makeSalt(bytes11(uint88(2)));
        vm.prank(orchestrator);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vaultFactory.create(PLAYER, address(0), "Player", "PLY", vaultSalt, stSalt);
    }

    function test_create_revertsZeroSalt() public {
        bytes32 vaultSalt = vaultFactory.makeSalt(bytes11(uint88(1)));
        vm.prank(orchestrator);
        vm.expectRevert(Errors.ZeroSalt.selector);
        vaultFactory.create(PLAYER, address(playerToken), "Player", "PLY", vaultSalt, bytes32(0));
    }

    function test_create_wiresVaultAndStToken() public {
        bytes32 vaultSalt = vaultFactory.makeSalt(bytes11(uint88(11)));
        bytes32 stSalt = vaultFactory.makeSalt(bytes11(uint88(12)));

        address predictedVault = vaultFactory.computeCreate3Address(vaultSalt);
        address predictedSt = vaultFactory.computeCreate3Address(stSalt);

        vm.prank(orchestrator);
        (address vaultAddr, address stAddr) =
            vaultFactory.create(PLAYER, address(playerToken), "Player", "PLY", vaultSalt, stSalt);

        assertEq(vaultAddr, predictedVault);
        assertEq(stAddr, predictedSt);

        PlayerVault vault = PlayerVault(payable(vaultAddr));
        StakedToken st = StakedToken(stAddr);

        assertEq(vault.playerId(), PLAYER);
        assertEq(vault.playerToken(), address(playerToken));
        assertEq(vault.stToken(), stAddr);
        assertEq(vault.owner(), orchestrator);
        assertTrue(vault.isActive());
        assertEq(st.vault(), vaultAddr);
        assertEq(st.name(), "Staked Player");
        assertEq(st.symbol(), "stPLY");
    }
}
