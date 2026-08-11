// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Vm } from "forge-std/Vm.sol";

import { MarketsErrors as Errors } from "@errors/markets/MarketsErrors.sol";
import { FeeRouter } from "@markets/FeeRouter.sol";
import { PlayerStatus } from "@types/registries/PlayerSetTypes.sol";

import { MarketsTestBase } from "./MarketsTestBase.sol";
import { AcceptingReceiver } from "./mocks/ETHReceivers.sol";

contract FeeRouterFactoryTest is MarketsTestBase {
    bytes32 internal constant PLAYER_A = keccak256("player-a");
    bytes32 internal constant PLAYER_B = keccak256("player-b");

    function test_initialize_setsOrchestratorAndBeacon() public view {
        assertEq(feeRouterFactory.orchestrator(), orchestrator);
        assertEq(feeRouterFactory.owner(), orchestrator);
        assertEq(feeRouterFactory.beacon().owner(), orchestrator);
        assertTrue(feeRouterFactory.implementation() != address(0));
    }

    function test_create_revertsUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        feeRouterFactory.create(PLAYER_A, address(0));
    }

    function test_create_revertsZeroId() public {
        vm.prank(orchestrator);
        vm.expectRevert(Errors.ZeroId.selector);
        feeRouterFactory.create(bytes32(0), address(0));
    }

    function test_create_allowsZeroHub() public {
        FeeRouter router = _createFeeRouter(PLAYER_A, address(0));
        assertEq(address(router), feeRouterFactory.feeRouterOf(PLAYER_A));
        assertEq(router.pbrFeeHub(), address(0));
        assertEq(uint8(router.status()), uint8(PlayerStatus.BONDING));
        assertEq(router.integrator(), address(hpTreasury));
        assertEq(router.minRelay(), 0.0001 ether);
    }

    function test_create_withHub_setsPbrFeeHub() public {
        AcceptingReceiver hub = new AcceptingReceiver();
        FeeRouter router = _createFeeRouter(PLAYER_A, address(hub));

        assertEq(router.pbrFeeHub(), address(hub));
        assertEq(router.playerId(), PLAYER_A);
        assertEq(router.minRelay(), 0.0001 ether);
        assertEq(router.integratorShareNum(), 10);
    }

    function test_create_emitsFeeRouterCreated() public {
        AcceptingReceiver hub = new AcceptingReceiver();
        tournamentRegistry.registerDomesticHub(address(hub));

        vm.prank(orchestrator);
        vm.recordLogs();
        address created = feeRouterFactory.create(PLAYER_A, address(hub));

        assertEq(feeRouterFactory.feeRouterOf(PLAYER_A), created);
        assertTrue(created.code.length > 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic0 = keccak256("FeeRouterCreated(bytes32,address,address)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic0) {
                assertEq(logs[i].topics[1], PLAYER_A);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), created);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), address(hub));
                found = true;
            }
        }
        assertTrue(found);
    }

    function test_create_idempotent_samePlayerId() public {
        AcceptingReceiver hub1 = new AcceptingReceiver();
        AcceptingReceiver hub2 = new AcceptingReceiver();

        FeeRouter first = _createFeeRouter(PLAYER_A, address(hub1));
        FeeRouter second = _createFeeRouter(PLAYER_A, address(hub2));

        assertEq(address(first), address(second));
        assertEq(first.pbrFeeHub(), address(hub1));
        assertEq(feeRouterFactory.feeRouterOf(PLAYER_A), address(first));
    }

    function test_create_distinctPlayers() public {
        AcceptingReceiver hub = new AcceptingReceiver();
        FeeRouter a = _createFeeRouter(PLAYER_A, address(hub));
        FeeRouter b = _createFeeRouter(PLAYER_B, address(hub));
        assertTrue(address(a) != address(b));
    }
}
