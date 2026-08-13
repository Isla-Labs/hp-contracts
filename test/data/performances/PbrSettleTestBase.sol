// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { AddressProvider } from "@src/AddressProvider.sol";
import { AddressKeys as Addresses } from "@addresses/AddressKeys.sol";
import { PbrSettle } from "@src/data/performances/PbrSettle.sol";

import { MockCvmRouter } from "./mocks/MockCvmRouter.sol";
import { MockPbrTreasury } from "./mocks/MockPbrTreasury.sol";
import { MockTournamentRegistry } from "./mocks/MockTournamentRegistry.sol";

abstract contract PbrSettleTestBase is Test {
    bytes32 internal constant TOURNAMENT = keccak256("tournament-1");
    bytes32 internal constant FIXTURE_1 = keccak256("fixture-1");
    bytes32 internal constant FIXTURE_2 = keccak256("fixture-2");
    bytes32 internal constant UTILIZED = keccak256("utilized-hash");

    uint16 internal constant YEAR = 2024;
    uint32 internal constant ROUND = 7;

    AddressProvider internal ap;
    MockCvmRouter internal cvmRouter;
    MockTournamentRegistry internal tournamentRegistry;
    MockPbrTreasury internal treasury;
    PbrSettle internal pbrSettle;

    address internal vaultA = makeAddr("vaultA");
    address internal vaultB = makeAddr("vaultB");

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        ap = new AddressProvider(address(this));
        cvmRouter = new MockCvmRouter();
        ap.setName(Addresses.CVM_ROUTER, address(cvmRouter));

        tournamentRegistry = new MockTournamentRegistry();
        treasury = new MockPbrTreasury();
        ap.setName(Addresses.TOURNAMENT_REGISTRY, address(tournamentRegistry));

        pbrSettle = new PbrSettle(address(ap));
        ap.setName(Addresses.PBR_SETTLE, address(pbrSettle));

        tournamentRegistry.setPbrTreasury(TOURNAMENT, address(treasury));
    }

    // --------------------------------------------
    //  Seed helpers
    // --------------------------------------------

    function _setFixtures(bytes32[] memory fixtures) internal {
        tournamentRegistry.setRound(TOURNAMENT, YEAR, ROUND, fixtures);
    }

    function _oneFixture(bytes32 fixtureId) internal pure returns (bytes32[] memory fixtures) {
        fixtures = new bytes32[](1);
        fixtures[0] = fixtureId;
    }

    function _twoFixtures(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory fixtures) {
        fixtures = new bytes32[](2);
        fixtures[0] = a;
        fixtures[1] = b;
    }

    // --------------------------------------------
    //  Settle / fulfill helpers
    // --------------------------------------------

    function _settleAsTreasury(bytes32 utilizedHash) internal returns (bytes32[] memory requestIds) {
        vm.prank(address(treasury));
        return pbrSettle.settleRound(TOURNAMENT, YEAR, ROUND, utilizedHash);
    }

    function _settleSimple() internal returns (bytes32 requestId) {
        _setFixtures(_oneFixture(FIXTURE_1));
        bytes32[] memory ids = _settleAsTreasury(UTILIZED);
        assertEq(ids.length, 1);
        return ids[0];
    }

    function _encodeOk(
        bytes32 utilizedHash,
        bytes32 fixtureDigest,
        address[] memory vaults,
        uint256[] memory points
    ) internal pure returns (bytes memory) {
        return abi.encode(utilizedHash, fixtureDigest, bytes("proof"), vaults, points);
    }

    function _fulfillOk(bytes32 requestId, bytes32 utilizedHash, bytes32 fixtureDigest) internal {
        address[] memory vaults = new address[](2);
        vaults[0] = vaultA;
        vaults[1] = vaultB;
        uint256[] memory points = new uint256[](2);
        points[0] = 10;
        points[1] = 20;
        cvmRouter.fulfill(requestId, _encodeOk(utilizedHash, fixtureDigest, vaults, points), "");
    }

    function _fulfillOkSimple(bytes32 requestId) internal {
        _fulfillOk(requestId, UTILIZED, keccak256(abi.encode(requestId, "digest")));
    }

    function _fulfillErr(bytes32 requestId, bytes memory err) internal {
        cvmRouter.fulfill(requestId, "", err);
    }

    function _fixtureFromRequest(bytes32 requestId) internal view returns (bytes32 fixtureId) {
        (,, bytes memory args) = cvmRouter.getPending(requestId);
        (,,, fixtureId,) = abi.decode(args, (bytes32, uint16, uint32, bytes32, bytes32));
    }
}
