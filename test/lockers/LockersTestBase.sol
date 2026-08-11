// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { AddressProvider } from "@src/AddressProvider.sol";
import { AddressKeys as Addresses } from "@addresses/AddressKeys.sol";
import { CreateXAddresses } from "@base/global/libraries/addresses/CreateX.sol";
import { Orchestrator } from "@governance/Orchestrator.sol";
import { TransferLocker } from "@src/lockers/assets/transfer/TransferLocker.sol";
import { DopplerLocker } from "@src/lockers/assets/deploy/DopplerLocker.sol";
import { DopplerConfig } from "@src/lockers/assets/deploy/config/DopplerConfig.sol";
import { DeployTournament } from "@src/lockers/tournaments/DeployTournament.sol";
import { LifecycleReason } from "@types/lockers/LifecycleTypes.sol";
import { PlayerStatus } from "@types/registries/PlayerSetTypes.sol";

import { MockAirlock } from "./mocks/MockAirlock.sol";
import { MockCvmRouter } from "./mocks/MockCvmRouter.sol";
import { MockFeeRouter } from "./mocks/MockFeeRouter.sol";
import { MockFeeRouterFactory } from "./mocks/MockFeeRouterFactory.sol";
import { MockPbrFeeHubFactory, MockPbrTreasuryFactory } from "./mocks/MockPbrFactories.sol";
import { MockPlayerSetRegistry } from "./mocks/MockPlayerSetRegistry.sol";
import { MockStakeVesting } from "./mocks/MockStakeVesting.sol";
import { MockTournamentRegistry } from "./mocks/MockTournamentRegistry.sol";

abstract contract LockersTestBase is Test {
    bytes32 internal constant LEAGUE = keccak256("league-1");
    bytes32 internal constant SEASON = keccak256("season-1");
    bytes32 internal constant PLAYER = keccak256("player-1");
    bytes32 internal constant PLAYER_B = keccak256("player-2");

    address internal dao = makeAddr("dao");
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

    TransferLocker internal transferLocker;
    DopplerLocker internal dopplerLocker;
    DopplerConfig internal dopplerConfig;
    DeployTournament internal deployTournament;

    function setUp() public virtual {
        ap = new AddressProvider(address(this));
        cvmRouter = new MockCvmRouter();
        ap.setName(Addresses.CVM_ROUTER, address(cvmRouter));

        orch = new Orchestrator(dao);
        tournamentRegistry = new MockTournamentRegistry();
        playerSetRegistry = new MockPlayerSetRegistry();
        feeRouterFactory = new MockFeeRouterFactory();
        treasuryFactory = new MockPbrTreasuryFactory();
        hubFactory = new MockPbrFeeHubFactory();
        airlock = new MockAirlock(address(orch));
        stakeVesting = new MockStakeVesting();

        ap.setName(Addresses.ORCHESTRATOR, address(orch));
        ap.setName(Addresses.TIMELOCK, timelock);
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

        dopplerConfig = _deployDopplerConfig();
        ap.setName(Addresses.DOPPLER_CONFIG, address(dopplerConfig));

        transferLocker = _deployTransferLocker();
        dopplerLocker = _deployDopplerLocker();
        deployTournament = _deployDeployTournament();

        vm.startPrank(dao);
        orch.addAuthorizedContract(address(transferLocker));
        orch.addAuthorizedContract(address(dopplerLocker));
        orch.addAuthorizedContract(address(deployTournament));
        vm.stopPrank();
    }

    function _deployTransferLocker() internal returns (TransferLocker) {
        return new TransferLocker(address(ap));
    }

    function _deployDopplerLocker() internal returns (DopplerLocker) {
        return new DopplerLocker(address(ap));
    }

    function _deployDopplerConfig() internal returns (DopplerConfig) {
        return new DopplerConfig(address(ap));
    }

    function _deployDeployTournament() internal returns (DeployTournament) {
        return new DeployTournament(address(ap));
    }

    /// @dev Admin path through Orchestrator.execute (wraps target reverts as ExecutionFailed).
    function _orchCall(address target, bytes memory data) internal returns (bytes memory) {
        vm.prank(dao);
        return orch.execute(target, 0, data);
    }

    /// @dev Call as Orchestrator directly so target custom errors surface unwrapped.
    function _ownerCall(address target, bytes memory data) internal returns (bytes memory ret) {
        vm.prank(address(orch));
        (bool ok, bytes memory raw) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(raw, 0x20), mload(raw))
            }
        }
        return raw;
    }

    /// @dev Call as Timelock so target custom errors surface unwrapped.
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
        vm.warp(block.timestamp + transferLocker.queueWait() + 1);
    }

    function _seedLeagueTopology(bytes32 leagueId, address hub) internal {
        tournamentRegistry.setTournamentExists(leagueId, true);
        tournamentRegistry.setPbrFeeHub(leagueId, hub);
        tournamentRegistry.setPbrTreasury(leagueId, makeAddr(string(abi.encodePacked("treasury-", leagueId))));
        tournamentRegistry.setLeagueLinked(leagueId, leagueId, true);
    }

    function _seedPlayerWithFeeRouter(bytes32 playerId, bytes32 leagueId, address hub) internal returns (address) {
        MockFeeRouter feeRouter = new MockFeeRouter();
        feeRouter.setPbrFeeHub(hub);
        playerSetRegistry.seedPlayer(
            playerId, PlayerStatus.GRADUATED, leagueId, address(feeRouter), hookDoppler, hookMigrator, hookMigrator
        );
        return address(feeRouter);
    }

    function _enqueueAsOwner(bytes32[] memory playerIds, LifecycleReason reason, uint32[] memory mins) internal {
        _ownerCall(address(transferLocker), abi.encodeCall(TransferLocker.enqueueLifecycle, (playerIds, reason, mins)));
    }

    function _fulfillLeagueTransfer(
        bytes32 requestId,
        bytes32 newLeagueId,
        bytes32[] memory activeTournamentIds
    ) internal {
        bytes memory response = abi.encode(newLeagueId, activeTournamentIds);
        cvmRouter.fulfill(requestId, response, "");
    }

    function _etchCreateX() internal {
        string memory artifact = vm.readFile("lib/doppler/lib/createx/artifacts/src/CreateX.sol/CreateX.json");
        bytes memory creationCode = vm.parseJsonBytes(artifact, ".bytecode");
        vm.etch(CreateXAddresses.CREATE_X, creationCode);
        (bool success, bytes memory runtimeBytecode) = CreateXAddresses.CREATE_X.call("");
        require(success, "CreateX init failed");
        vm.etch(CreateXAddresses.CREATE_X, runtimeBytecode);
    }
}
