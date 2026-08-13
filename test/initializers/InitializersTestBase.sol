// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { AddressProvider } from "@src/AddressProvider.sol";
import { AddressKeys as Addresses } from "@addresses/AddressKeys.sol";
import { Orchestrator } from "@src/Orchestrator.sol";
import { DopplerConfig } from "@src/initializers/markets/base/DopplerConfig.sol";
import { MarketInitializer } from "@src/initializers/markets/MarketInitializer.sol";
import { LifecycleManager } from "@src/initializers/lifecycle/LifecycleManager.sol";
import { TournamentInitializer } from "@src/initializers/tournaments/TournamentInitializer.sol";
import { LifecycleReason } from "@types/initializers/LifecycleTypes.sol";
import { PlayerStatus } from "@types/registries/PlayerSetTypes.sol";
import { TournamentType } from "@types/registries/TournamentTypes.sol";

import { MockAirlock } from "./mocks/MockAirlock.sol";
import { MockCvmRouter } from "./mocks/MockCvmRouter.sol";
import { MockFeeRouter } from "./mocks/MockFeeRouter.sol";
import { MockFeeRouterFactory } from "./mocks/MockFeeRouterFactory.sol";
import { MockPbrFeeHubFactory, MockPbrTreasuryFactory } from "./mocks/MockPbrFactories.sol";
import { MockPlayerSetRegistry } from "./mocks/MockPlayerSetRegistry.sol";
import { MockStakeVesting } from "./mocks/MockStakeVesting.sol";
import { MockTournamentRegistry } from "./mocks/MockTournamentRegistry.sol";

abstract contract InitializersTestBase is Test {
    bytes32 internal constant LEAGUE = keccak256("league-1");
    bytes32 internal constant SEASON = keccak256("season-1");
    bytes32 internal constant PLAYER = keccak256("player-1");
    bytes32 internal constant PLAYER_B = keccak256("player-2");

    uint256 internal constant DEPLOY_COOLDOWN = 1 hours;

    address internal timelock = makeAddr("timelock");
    address internal eligibilityVerifier = makeAddr("eligibilityVerifier");
    address internal hookDoppler = makeAddr("hookDoppler");
    address internal hookMigrator = makeAddr("hookMigrator");
    address internal hpTreasury = makeAddr("hpTreasury");

    AddressProvider internal ap;
    Orchestrator internal orch;
    MockCvmRouter internal cvmRouter;
    MockTournamentRegistry internal tournamentRegistry;
    MockPlayerSetRegistry internal playerSetRegistry;
    MockFeeRouterFactory internal feeRouterFactory;
    MockPbrTreasuryFactory internal treasuryFactory;
    MockPbrFeeHubFactory internal hubFactory;
    MockAirlock internal airlock;
    MockStakeVesting internal stakeVesting;

    LifecycleManager internal lifecycleManager;
    MarketInitializer internal marketInitializer;
    DopplerConfig internal dopplerConfig;
    TournamentInitializer internal tournamentInitializer;

    function setUp() public virtual {
        ap = new AddressProvider(address(this));
        cvmRouter = new MockCvmRouter();
        ap.setName(Addresses.CVM_ROUTER, address(cvmRouter));

        tournamentRegistry = new MockTournamentRegistry();
        playerSetRegistry = new MockPlayerSetRegistry();
        feeRouterFactory = new MockFeeRouterFactory();
        treasuryFactory = new MockPbrTreasuryFactory();
        hubFactory = new MockPbrFeeHubFactory();
        airlock = new MockAirlock(address(this));
        stakeVesting = new MockStakeVesting();

        ap.setName(Addresses.HP_MULTISIG, address(this));
        ap.setName(Addresses.TIMELOCK, timelock);
        ap.setName(Addresses.ELIGIBILITY_VERIFIER, eligibilityVerifier);
        ap.setName(Addresses.PLAYER_SET_REGISTRY, address(playerSetRegistry));
        ap.setName(Addresses.TOURNAMENT_REGISTRY, address(tournamentRegistry));
        ap.setName(Addresses.FEE_ROUTER_FACTORY, address(feeRouterFactory));
        ap.setName(Addresses.PBR_TREASURY_FACTORY, address(treasuryFactory));
        ap.setName(Addresses.PBR_FEE_HUB_FACTORY, address(hubFactory));
        ap.setName(Addresses.HP_TREASURY, hpTreasury);
        ap.setName(Addresses.STAKE_VESTING, address(stakeVesting));
        ap.setName(Addresses.DOPPLER_AIRLOCK, address(airlock));
        ap.setName(Addresses.DN404_FACTORY, makeAddr("dn404Factory"));
        ap.setName(Addresses.PLAYER_VAULT_FACTORY, makeAddr("playerVaultFactory"));
        ap.setName(Addresses.LAUNCHPAD_GOVERNANCE_FACTORY, makeAddr("govFactory"));
        ap.setName(Addresses.DOPPLER_HOOK_INITIALIZER, hookDoppler);
        ap.setName(Addresses.DOPPLER_HOOK_MIGRATOR, hookMigrator);
        ap.setName(Addresses.REHYPE_DOPPLER_HOOK_INITIALIZER, makeAddr("rehypeInit"));
        ap.setName(Addresses.REHYPE_DOPPLER_HOOK_MIGRATOR, makeAddr("rehypeMigrator"));

        dopplerConfig = new DopplerConfig(address(ap));
        ap.setName(Addresses.DOPPLER_CONFIG, address(dopplerConfig));

        orch = new Orchestrator(address(ap), DEPLOY_COOLDOWN);
        ap.setName(Addresses.ORCHESTRATOR, address(orch));

        marketInitializer = new MarketInitializer(address(ap));
        lifecycleManager = new LifecycleManager(address(ap));
        tournamentInitializer = new TournamentInitializer(address(ap));

        ap.setName(Addresses.MARKET_INITIALIZER, address(marketInitializer));
        ap.setName(Addresses.LIFECYCLE_MANAGER, address(lifecycleManager));
        ap.setName(Addresses.TOURNAMENT_INITIALIZER, address(tournamentInitializer));
    }

    // --------------------------------------------
    //  Orchestrator helpers
    // --------------------------------------------

    function _queuePlayers(bytes32 leagueId, bytes32 seasonId, bytes32[] memory playerIds) internal {
        orch.queueAssets(leagueId, seasonId, playerIds);
    }

    function _queueLifecycle(bytes32[] memory playerIds, LifecycleReason reason, uint32[] memory mins) internal {
        orch.queueChanges(playerIds, reason, mins);
    }

    function _processQueue() internal returns (bytes32) {
        return orch.processQueue();
    }

    function _processLifecycle() internal returns (bytes32) {
        return orch.processLifecycle();
    }

    function _asOrch(address target, bytes memory data) internal returns (bytes memory ret) {
        vm.prank(address(orch));
        (bool ok, bytes memory raw) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(raw, 0x20), mload(raw))
            }
        }
        return raw;
    }

    function _timelockCall(address target, bytes memory data) internal returns (bytes memory ret) {
        vm.prank(timelock);
        (bool ok, bytes memory raw) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(raw, 0x20), mload(raw))
            }
        }
        return raw;
    }

    function _warpPastQueueWait() internal {
        vm.warp(block.timestamp + lifecycleManager.queueWait() + 1);
    }

    function _warpPastMarketQueueWait() internal {
        vm.warp(block.timestamp + marketInitializer.queueWait() + 1);
    }

    function _seedLeagueTopology(bytes32 leagueId, address hub) internal {
        tournamentRegistry.setTournamentExists(leagueId, true);
        tournamentRegistry.setPbrFeeHub(leagueId, hub);
        tournamentRegistry.setPbrTreasury(leagueId, makeAddr(string(abi.encodePacked("treasury-", leagueId))));
        tournamentRegistry.setLeagueLinked(leagueId, leagueId, true);
        tournamentRegistry.setTournamentType(leagueId, TournamentType.DOMESTIC_LEAGUE);
    }

    function _seedPlayerWithFeeRouter(bytes32 playerId, bytes32 leagueId, address hub) internal returns (address) {
        MockFeeRouter feeRouter = new MockFeeRouter();
        feeRouter.setPbrFeeHub(hub);
        playerSetRegistry.seedPlayer(
            playerId, PlayerStatus.GRADUATED, leagueId, address(feeRouter), hookDoppler, hookMigrator, hookMigrator
        );
        return address(feeRouter);
    }

    function _fulfillMetadata(
        bytes32 requestId,
        bytes32 seasonId,
        bytes32[] memory ids,
        string memory name,
        string memory symbol
    ) internal {
        string[] memory names = new string[](ids.length);
        string[] memory symbols = new string[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            names[i] = name;
            symbols[i] = symbol;
        }
        cvmRouter.fulfill(requestId, abi.encode(seasonId, ids, names, symbols), "");
    }

    function _fulfillLeagueTransfer(
        bytes32 requestId,
        bytes32 newLeagueId,
        bytes32[] memory activeTournamentIds
    ) internal {
        cvmRouter.fulfill(requestId, abi.encode(newLeagueId, activeTournamentIds), "");
    }

    function _queueThroughQueued(bytes32 playerId) internal {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = playerId;
        _queuePlayers(LEAGUE, SEASON, ids);
        _fulfillMetadata(cvmRouter.lastRequestId(), SEASON, ids, "Player", "PLY");
    }
}
