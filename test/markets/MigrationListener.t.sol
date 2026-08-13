// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";

import { AddressKeys as Addresses } from "@addresses/AddressKeys.sol";
import { MigrationErrors as Errors } from "@errors/data/MigrationErrors.sol";
import { MigrationEvents as Events } from "@events/data/MigrationEvents.sol";
import { AddressProvider } from "@src/AddressProvider.sol";
import { MigrationListener } from "@src/data/markets/MigrationListener.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";
import { PlayerStatus } from "@types/registries/PlayerSetTypes.sol";

import { MockCvmRouter } from "../data/eligibility/mocks/MockCvmRouter.sol";
import {
    MockAirlockMigrate,
    MockDopplerConfigModules,
    MockDopplerHookInitializer,
    MockDopplerHookMigrator,
    MockMigrationPlayerSetRegistry
} from "./mocks/MockMigrationDeps.sol";

contract MigrationListenerTest is Test {
    uint8 internal constant STATUS_INITIALIZED = 1;
    uint8 internal constant STATUS_EXITED = 4;

    bytes32 internal constant PLAYER = keccak256("player");
    address internal token;

    AddressProvider internal ap;
    MockCvmRouter internal cvmRouter;
    MockMigrationPlayerSetRegistry internal psr;
    MockDopplerConfigModules internal dopplerConfig;
    MockDopplerHookInitializer internal poolInitializer;
    MockDopplerHookMigrator internal liquidityMigrator;
    MockAirlockMigrate internal airlock;
    MigrationListener internal listener;

    PoolKey internal bondingPool;
    PoolKey internal spotPool;

    function setUp() public {
        token = makeAddr("token");

        ap = new AddressProvider(address(this));
        cvmRouter = new MockCvmRouter();
        ap.setName(Addresses.CVM_ROUTER, address(cvmRouter));

        psr = new MockMigrationPlayerSetRegistry();
        dopplerConfig = new MockDopplerConfigModules();
        poolInitializer = new MockDopplerHookInitializer();
        liquidityMigrator = new MockDopplerHookMigrator();
        airlock = new MockAirlockMigrate();
        airlock.setInitializer(address(poolInitializer));
        dopplerConfig.set(address(airlock), address(poolInitializer), address(liquidityMigrator));

        ap.setName(Addresses.PLAYER_SET_REGISTRY, address(psr));
        ap.setName(Addresses.DOPPLER_CONFIG, address(dopplerConfig));

        listener = new MigrationListener(address(ap), 1 minutes);
        ap.setName(Addresses.MIGRATION_LISTENER, address(listener));

        bondingPool = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(poolInitializer))
        });
        spotPool = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(liquidityMigrator))
        });

        psr.seedBonding(PLAYER, token, address(poolInitializer), address(liquidityMigrator), address(0xFEE));
        poolInitializer.setState(token, STATUS_INITIALIZED, bondingPool, int24(-90_832));
        liquidityMigrator.setPairAndPool(token, address(0), token, spotPool);
    }

    // --------------------------------------------
    //  syncMigrations (direct batch)
    // --------------------------------------------

    function test_syncMigrations_alreadyExited_graduates() public {
        poolInitializer.setStatus(token, STATUS_EXITED);

        address[] memory tokens = new address[](1);
        tokens[0] = token;

        vm.expectEmit(true, true, false, true);
        emit Events.MigrationSynced(PLAYER, token, address(liquidityMigrator));

        listener.syncMigrations(tokens);

        assertEq(psr.graduateCount(), 1);
        assertEq(psr.lastGraduatedPlayerId(), PLAYER);
        assertEq(airlock.migrateCount(token), 0);
        assertEq(uint8(psr.getPlayerSet(PLAYER).status), uint8(PlayerStatus.GRADUATED));
    }

    function test_syncMigrations_ready_migratesThenGraduates() public {
        address[] memory tokens = new address[](1);
        tokens[0] = token;

        listener.syncMigrations(tokens);

        assertEq(airlock.migrateCount(token), 1);
        assertEq(psr.graduateCount(), 1);
        assertEq(uint8(psr.getPlayerSet(PLAYER).status), uint8(PlayerStatus.GRADUATED));
    }

    function test_syncMigrations_migrateRace_skipsGraduate() public {
        airlock.setShouldRevert(token, true);

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        listener.syncMigrations(tokens);

        assertEq(airlock.migrateCount(token), 0);
        assertEq(psr.graduateCount(), 0);
        assertEq(uint8(psr.getPlayerSet(PLAYER).status), uint8(PlayerStatus.BONDING));
    }

    function test_syncMigrations_revertsEmpty() public {
        address[] memory tokens = new address[](0);
        vm.expectRevert(Errors.EmptyBatch.selector);
        listener.syncMigrations(tokens);
    }

    function test_syncMigrations_revertsTooLarge() public {
        address[] memory tokens = new address[](11);
        for (uint256 i; i < 11; ++i) {
            tokens[i] = address(uint160(i + 1));
        }
        vm.expectRevert(abi.encodeWithSelector(Errors.BatchTooLarge.selector, 11, 10));
        listener.syncMigrations(tokens);
    }

    function test_syncMigrations_skipsNotBonding() public {
        psr.setStatus(PLAYER, PlayerStatus.GRADUATED);
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        listener.syncMigrations(tokens);
        assertEq(psr.graduateCount(), 0);
        assertEq(airlock.migrateCount(token), 0);
    }

    function test_syncMigrations_hookMismatch_skips() public {
        poolInitializer.setStatus(token, STATUS_EXITED);
        // Spot pool hooks ≠ registered hookMigrator
        PoolKey memory badSpot = spotPool;
        badSpot.hooks = IHooks(address(0xBAD));
        liquidityMigrator.setPairAndPool(token, address(0), token, badSpot);

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        listener.syncMigrations(tokens);

        assertEq(psr.graduateCount(), 0);
    }

    // --------------------------------------------
    //  scanMigrations (oracle)
    // --------------------------------------------

    function test_scanMigrations_rateLimited() public {
        bytes32 requestId = listener.scanMigrations();
        assertTrue(requestId != bytes32(0));

        (address consumer, CvmJob job,) = cvmRouter.getPending(requestId);
        assertEq(consumer, address(listener));
        assertEq(uint8(job), uint8(CvmJob.BondingMigrationScan));

        vm.expectRevert();
        listener.scanMigrations();

        vm.warp(block.timestamp + 1 minutes);
        bytes32 requestId2 = listener.scanMigrations();
        assertTrue(requestId2 != requestId);
    }

    function test_scanMigrations_fulfill_appliesSync() public {
        bytes32 requestId = listener.scanMigrations();

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        cvmRouter.fulfill(requestId, abi.encode(tokens), "");

        assertEq(airlock.migrateCount(token), 1);
        assertEq(psr.graduateCount(), 1);
    }

    function test_scanMigrations_fulfill_err_noop() public {
        bytes32 requestId = listener.scanMigrations();
        cvmRouter.fulfill(requestId, "", abi.encode("boom"));
        assertEq(psr.graduateCount(), 0);
        assertEq(airlock.migrateCount(token), 0);
    }
}
