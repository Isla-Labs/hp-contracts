// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol";

import { AddressProvider } from "@src/AddressProvider.sol";
import { AddressKeys as Addresses } from "@addresses/AddressKeys.sol";
import { CreateXAddresses } from "@base/global/libraries/addresses/CreateX.sol";
import { RoundStatus } from "@types/vaults/VaultTypes.sol";
import { PlayerVault } from "@vaults/PlayerVault.sol";
import { PbrTreasury } from "@vaults/PbrTreasury.sol";
import { StakedToken } from "@vaults/StakedToken.sol";
import { PlayerVaultFactory } from "@vaults/factories/PlayerVaultFactory.sol";
import { PbrTreasuryFactory } from "@vaults/factories/PbrTreasuryFactory.sol";

import { MockPbrSettle } from "./mocks/MockPbrSettle.sol";
import { MockPlayerSetRegistry } from "./mocks/MockPlayerSetRegistry.sol";
import { MockPlayerToken } from "./mocks/MockPlayerToken.sol";
import { MockTournamentRegistry } from "./mocks/MockTournamentRegistry.sol";

abstract contract VaultsTestBase is Test {
    uint16 internal constant START_YEAR = 2025;
    bytes32 internal constant TOURNAMENT = keccak256("tournament-1");
    bytes32 internal constant PLAYER = keccak256("player-1");

    address internal dao = makeAddr("dao");
    address internal orchestrator = makeAddr("orchestrator");
    address internal user = makeAddr("user");
    address internal user2 = makeAddr("user2");

    AddressProvider internal ap;
    MockTournamentRegistry internal tournamentRegistry;
    MockPlayerSetRegistry internal playerSetRegistry;
    MockPlayerToken internal playerToken;
    MockPbrSettle internal pbrSettle;

    UpgradeableBeacon internal vaultBeacon;
    UpgradeableBeacon internal treasuryBeacon;

    PlayerVaultFactory internal vaultFactory;
    PbrTreasuryFactory internal treasuryFactory;

    function setUp() public virtual {
        ap = new AddressProvider(address(this));
        tournamentRegistry = new MockTournamentRegistry();
        playerSetRegistry = new MockPlayerSetRegistry();
        playerToken = new MockPlayerToken();
        pbrSettle = new MockPbrSettle();

        ap.setName(Addresses.ORCHESTRATOR, orchestrator);
        ap.setName(Addresses.TOURNAMENT_REGISTRY, address(tournamentRegistry));
        ap.setName(Addresses.PLAYER_SET_REGISTRY, address(playerSetRegistry));
        ap.setName(Addresses.PBR_SETTLE, address(pbrSettle));
        // PlayerVault.initialize caches STAKE_ROUTER; real router tests overwrite before deploy.
        ap.setName(Addresses.STAKE_ROUTER, makeAddr("stakeRouter"));

        bytes32[] memory tournaments = new bytes32[](1);
        tournaments[0] = TOURNAMENT;
        playerSetRegistry.setActiveTournaments(PLAYER, tournaments);

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

        bytes32[] memory tournaments = new bytes32[](1);
        tournaments[0] = TOURNAMENT;
        playerSetRegistry.setActiveTournaments(playerId, tournaments);
    }

    function _deployTreasury(bytes32 tournamentId, uint16 seasonStartYear) internal returns (PbrTreasury treasury) {
        bytes memory initData = abi.encodeCall(PbrTreasury.initialize, (tournamentId, seasonStartYear));
        treasury = PbrTreasury(payable(address(new BeaconProxy(address(treasuryBeacon), initData))));
        tournamentRegistry.setPbrTreasury(tournamentId, address(treasury));
    }

    function _registerVault(PbrTreasury treasury, address vault) internal {
        bytes32 tournamentId = treasury.tournamentId();
        // Mirror TournamentRegistry order: vault cache before treasury register.
        vm.prank(address(tournamentRegistry));
        PlayerVault(payable(vault)).syncActiveTreasury(tournamentId, address(treasury), true);
        vm.prank(address(tournamentRegistry));
        treasury.syncRegisterVault(vault);
    }

    function _publishRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        uint64 startTime,
        uint64 endTime,
        uint32 finalRound
    ) internal {
        tournamentRegistry.setRound(tournamentId, seasonStartYear, roundNumber, startTime, endTime, true);
        tournamentRegistry.setFinalRound(tournamentId, seasonStartYear, finalRound);
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

    function _etchCreateX() internal {
        string memory artifact = vm.readFile("lib/doppler/lib/createx/artifacts/src/CreateX.sol/CreateX.json");
        bytes memory creationCode = vm.parseJsonBytes(artifact, ".bytecode");

        vm.etch(CreateXAddresses.CREATE_X, creationCode);
        (bool success, bytes memory runtimeBytecode) = CreateXAddresses.CREATE_X.call("");
        require(success, "CreateX init failed");
        vm.etch(CreateXAddresses.CREATE_X, runtimeBytecode);
        require(CreateXAddresses.CREATE_X.code.length > 0, "CreateX etch empty");
    }

    function _lockVaults(PbrTreasury treasury) internal {
        // Cut-off is previous block — ensure stake checkpoints are in the past.
        vm.roll(block.number + 1);
        treasury.lockVaults();
    }

    /// @dev `requestSettle` → apply fixture scores → Claimable.
    function _settle(PbrTreasury treasury, address[] memory vaults, uint256[] memory points) internal {
        (uint16 seasonStartYear, uint32 round,) = treasury.getCursors();
        RoundStatus status = treasury.getRound(seasonStartYear, round).status;
        if (status == RoundStatus.Locked) {
            treasury.requestSettle();
        } else if (status != RoundStatus.SettlePending) {
            revert("round not ready to settle");
        }

        if (uint8(treasury.getRound(seasonStartYear, round).status) == uint8(RoundStatus.Claimable)) {
            require(vaults.length == 0, "expected empty utilized");
            return;
        }

        address[] memory utilized = treasury.getUtilizedVaults(seasonStartYear, round);
        require(vaults.length == utilized.length, "vaults/utilized length");
        require(points.length == utilized.length, "points/utilized length");
        for (uint256 i; i < utilized.length; ++i) {
            require(vaults[i] == utilized[i], "vault order");
        }

        bytes32[] memory fixtures = tournamentRegistry.getRound(TOURNAMENT, seasonStartYear, round).fixtureIds;
        require(fixtures.length > 0, "no fixtures");

        vm.prank(address(pbrSettle));
        bool done =
            treasury.applyFixtureSettlement(fixtures[0], keccak256(abi.encode(fixtures[0], "digest")), vaults, points);

        address[] memory emptyVaults = new address[](0);
        uint256[] memory emptyPoints = new uint256[](0);
        for (uint256 i = 1; i < fixtures.length; ++i) {
            vm.prank(address(pbrSettle));
            done = treasury.applyFixtureSettlement(
                fixtures[i], keccak256(abi.encode(fixtures[i], "digest")), emptyVaults, emptyPoints
            );
        }

        require(done, "settle incomplete");
        require(
            uint8(treasury.getRound(seasonStartYear, round).status) == uint8(RoundStatus.Claimable), "not claimable"
        );
    }
}
