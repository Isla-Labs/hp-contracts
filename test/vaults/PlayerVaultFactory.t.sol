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

    function test_constructor_setsTimelockOwnedBeacon() public view {
        assertEq(vaultFactory.beacon().owner(), timelock);
        assertTrue(vaultFactory.implementation() != address(0));
    }

    function test_create_revertsUnauthorized() public {
        bytes32 vaultSalt = _permissionedSalt(address(vaultFactory), bytes11(uint88(1)));
        bytes32 stSalt = _permissionedSalt(address(vaultFactory), bytes11(uint88(2)));
        vm.expectRevert(Errors.Unauthorized.selector);
        vaultFactory.create(PLAYER, address(playerToken), "Player", "PLY", vaultSalt, stSalt, "ipfs://staked");
    }

    function test_create_revertsZeroId() public {
        bytes32 vaultSalt = _permissionedSalt(address(vaultFactory), bytes11(uint88(1)));
        bytes32 stSalt = _permissionedSalt(address(vaultFactory), bytes11(uint88(2)));
        vm.prank(orchestrator);
        vm.expectRevert(Errors.ZeroId.selector);
        vaultFactory.create(bytes32(0), address(playerToken), "Player", "PLY", vaultSalt, stSalt, "ipfs://staked");
    }

    function test_create_revertsZeroToken() public {
        bytes32 vaultSalt = _permissionedSalt(address(vaultFactory), bytes11(uint88(1)));
        bytes32 stSalt = _permissionedSalt(address(vaultFactory), bytes11(uint88(2)));
        vm.prank(orchestrator);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vaultFactory.create(PLAYER, address(0), "Player", "PLY", vaultSalt, stSalt, "ipfs://staked");
    }

    function test_create_revertsZeroSalt() public {
        bytes32 vaultSalt = _permissionedSalt(address(vaultFactory), bytes11(uint88(1)));
        vm.prank(orchestrator);
        vm.expectRevert(Errors.ZeroSalt.selector);
        vaultFactory.create(PLAYER, address(playerToken), "Player", "PLY", vaultSalt, bytes32(0), "ipfs://staked");
    }

    function test_create_revertsEmptyURI() public {
        bytes32 vaultSalt = _permissionedSalt(address(vaultFactory), bytes11(uint88(1)));
        bytes32 stSalt = _permissionedSalt(address(vaultFactory), bytes11(uint88(2)));
        vm.prank(orchestrator);
        vm.expectRevert(Errors.EmptyURI.selector);
        vaultFactory.create(PLAYER, address(playerToken), "Player", "PLY", vaultSalt, stSalt, "");
    }

    function test_create_wiresVaultAndStToken() public {
        bytes32 vaultSalt = _permissionedSalt(address(vaultFactory), bytes11(uint88(11)));
        bytes32 stSalt = _permissionedSalt(address(vaultFactory), bytes11(uint88(12)));

        address predictedVault = _predictCreate3(address(vaultFactory), vaultSalt);
        address predictedSt = _predictCreate3(address(vaultFactory), stSalt);

        vm.prank(orchestrator);
        (address vaultAddr, address stAddr) =
            vaultFactory.create(PLAYER, address(playerToken), "Player", "PLY", vaultSalt, stSalt, "ipfs://staked");

        assertEq(vaultAddr, predictedVault);
        assertEq(stAddr, predictedSt);

        PlayerVault vault = PlayerVault(payable(vaultAddr));
        StakedToken st = StakedToken(stAddr);

        assertEq(vault.playerId(), PLAYER);
        assertEq(vault.playerToken(), address(playerToken));
        assertEq(vault.stToken(), stAddr);
        assertTrue(vault.isActive());
        assertEq(st.vault(), vaultAddr);
        assertEq(st.name(), "Staked Player");
        assertEq(st.symbol(), "PLY42");
        assertEq(st.contractURI(), "ipfs://staked");
    }
}
