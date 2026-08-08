// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol";

import { AddressProvider } from "@src/AddressProvider.sol";
import { AddressKeys as Addresses } from "@addresses/AddressKeys.sol";
import { CreateXAddresses } from "@base/global/libraries/addresses/CreateX.sol";
import { PlayerVault } from "@vaults/PlayerVault.sol";
import { PbrTreasury } from "@vaults/PbrTreasury.sol";
import { StakedToken } from "@vaults/StakedToken.sol";
import { PlayerVaultFactory } from "@vaults/factories/PlayerVaultFactory.sol";
import { PbrTreasuryFactory } from "@vaults/factories/PbrTreasuryFactory.sol";

import { MockPlayerSetRegistry } from "./mocks/MockPlayerSetRegistry.sol";
import { MockPlayerToken } from "./mocks/MockPlayerToken.sol";
import { MockTournamentRegistry } from "./mocks/MockTournamentRegistry.sol";

abstract contract VaultsTestBase is Test {
    uint16 internal constant SEASON = 2025;
    bytes32 internal constant TOURNAMENT = keccak256("tournament-1");
    bytes32 internal constant PLAYER = keccak256("player-1");

    address internal dao = makeAddr("dao");
    address internal orchestrator = makeAddr("orchestrator");
    address internal pbrSettle = makeAddr("pbrSettle");
    address internal user = makeAddr("user");
    address internal user2 = makeAddr("user2");

    AddressProvider internal ap;
    MockTournamentRegistry internal tournamentRegistry;
    MockPlayerSetRegistry internal playerSetRegistry;
    MockPlayerToken internal playerToken;

    UpgradeableBeacon internal vaultBeacon;
    UpgradeableBeacon internal treasuryBeacon;

    PlayerVaultFactory internal vaultFactory;
    PbrTreasuryFactory internal treasuryFactory;

    function setUp() public virtual {
        ap = new AddressProvider(address(this));
        tournamentRegistry = new MockTournamentRegistry();
        playerSetRegistry = new MockPlayerSetRegistry();
        playerToken = new MockPlayerToken();

        ap.setName(Addresses.ORCHESTRATOR, orchestrator);
        ap.setName(Addresses.TOURNAMENT_REGISTRY, address(tournamentRegistry));
        ap.setName(Addresses.PLAYER_SET_REGISTRY, address(playerSetRegistry));
        ap.setName(Addresses.PBR_SETTLE, pbrSettle);

        vaultBeacon = new UpgradeableBeacon(address(new PlayerVault(address(ap))), orchestrator);
        treasuryBeacon = new UpgradeableBeacon(address(new PbrTreasury(address(ap))), orchestrator);

        vaultFactory = _deployVaultFactory();
        treasuryFactory = _deployTreasuryFactory();
    }

    function _deployVaultFactory() internal returns (PlayerVaultFactory) {
        PlayerVaultFactory impl = new PlayerVaultFactory(address(ap));
        return PlayerVaultFactory(
            address(
                new TransparentUpgradeableProxy(address(impl), dao, abi.encodeCall(PlayerVaultFactory.initialize, ()))
            )
        );
    }

    function _deployTreasuryFactory() internal returns (PbrTreasuryFactory) {
        PbrTreasuryFactory impl = new PbrTreasuryFactory(address(ap));
        return PbrTreasuryFactory(
            address(
                new TransparentUpgradeableProxy(address(impl), dao, abi.encodeCall(PbrTreasuryFactory.initialize, ()))
            )
        );
    }

    function _deployVault(bytes32 playerId) internal returns (PlayerVault vault, StakedToken stToken) {
        vault = PlayerVault(payable(address(new BeaconProxy(address(vaultBeacon), ""))));
        stToken = new StakedToken("Staked Player", "stPLY", address(vault));
        vault.initialize(playerId, address(playerToken), address(stToken));
    }

    function _deployTreasury(bytes32 tournamentId, uint16 season) internal returns (PbrTreasury treasury) {
        bytes memory initData = abi.encodeCall(PbrTreasury.initialize, (tournamentId, season));
        treasury = PbrTreasury(payable(address(new BeaconProxy(address(treasuryBeacon), initData))));
        tournamentRegistry.setPbrTreasury(tournamentId, address(treasury));
    }

    function _registerVault(PbrTreasury treasury, address vault) internal {
        vm.prank(address(tournamentRegistry));
        treasury.syncRegisterVault(vault);
    }

    function _publishRound(
        bytes32 tournamentId,
        uint16 season,
        uint32 roundNumber,
        uint64 startTime,
        uint64 endTime,
        uint32 finalRound
    ) internal {
        tournamentRegistry.setRound(tournamentId, season, roundNumber, startTime, endTime, true);
        tournamentRegistry.setFinalRound(tournamentId, season, finalRound);
    }

    function _stake(address staker, PlayerVault vault, uint256 amount) internal {
        playerToken.mint(staker, amount);
        vm.startPrank(staker);
        playerToken.approve(address(vault), amount);
        vault.stake(amount);
        vm.stopPrank();
    }

    function _sendEth(address to, uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = to.call{ value: amount }("");
        require(ok, "eth send failed");
    }

    /// @dev Etch canonical CreateX without compiling its 0.8.23-pinned sources.
    function _etchCreateX() internal {
        string memory artifact = vm.readFile("lib/doppler/lib/createx/artifacts/src/CreateX.sol/CreateX.json");
        bytes memory creationCode = vm.parseJsonBytes(artifact, ".bytecode");

        vm.etch(CreateXAddresses.CREATE_X, creationCode);
        (bool success, bytes memory runtimeBytecode) = CreateXAddresses.CREATE_X.call("");
        require(success, "CreateX init failed");
        vm.etch(CreateXAddresses.CREATE_X, runtimeBytecode);
        require(CreateXAddresses.CREATE_X.code.length > 0, "CreateX etch empty");
    }

    function _lockAndSnapshot(PbrTreasury treasury) internal {
        treasury.lock();
        (uint256 processed, bool done) = treasury.snapshotBatch();
        processed;
        require(done, "snapshot incomplete");
    }

    function _settle(
        PbrTreasury treasury,
        address[] memory vaults,
        uint256[] memory points,
        uint256 mAdj
    ) internal {
        vm.prank(orchestrator);
        treasury.settle(vaults, points, mAdj);
    }
}
