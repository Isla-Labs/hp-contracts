// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol";

import { AddressProvider } from "@src/AddressProvider.sol";
import { AddressKeys as Addresses } from "@addresses/AddressKeys.sol";
import { FeeRouter } from "@markets/FeeRouter.sol";
import { FeeRouterFactory } from "@markets/factories/FeeRouterFactory.sol";
import { PbrFeeHub } from "@markets/PbrFeeHub.sol";
import { PbrFeeHubFactory } from "@markets/factories/PbrFeeHubFactory.sol";

import { AcceptingReceiver } from "./mocks/ETHReceivers.sol";
import { MockTournamentRegistry } from "./mocks/MockTournamentRegistry.sol";

abstract contract MarketsTestBase is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    address internal dao = makeAddr("dao");
    address internal orchestrator = makeAddr("orchestrator");
    address internal playerSetRegistry = makeAddr("playerSetRegistry");

    AddressProvider internal ap;
    MockTournamentRegistry internal tournamentRegistry;
    AcceptingReceiver internal hpTreasury;

    FeeRouterFactory internal feeRouterFactory;
    PbrFeeHubFactory internal pbrFeeHubFactory;

    function setUp() public virtual {
        ap = new AddressProvider(address(this));
        tournamentRegistry = new MockTournamentRegistry();
        hpTreasury = new AcceptingReceiver();

        ap.setName(Addresses.ORCHESTRATOR, orchestrator);
        ap.setName(Addresses.HP_TREASURY, address(hpTreasury));
        ap.setName(Addresses.TOURNAMENT_REGISTRY, address(tournamentRegistry));
        ap.setName(Addresses.PLAYER_SET_REGISTRY, playerSetRegistry);

        feeRouterFactory = _deployFeeRouterFactory();
        pbrFeeHubFactory = _deployPbrFeeHubFactory();
    }

    function _deployFeeRouterFactory() internal returns (FeeRouterFactory) {
        FeeRouterFactory impl = new FeeRouterFactory(address(ap));
        return FeeRouterFactory(
            address(
                new TransparentUpgradeableProxy(address(impl), dao, abi.encodeCall(FeeRouterFactory.initialize, ()))
            )
        );
    }

    function _deployPbrFeeHubFactory() internal returns (PbrFeeHubFactory) {
        PbrFeeHubFactory impl = new PbrFeeHubFactory(address(ap));
        return PbrFeeHubFactory(
            address(
                new TransparentUpgradeableProxy(address(impl), dao, abi.encodeCall(PbrFeeHubFactory.initialize, ()))
            )
        );
    }

    function _createFeeRouter(bytes32 playerId, address pbrFeeHub) internal returns (FeeRouter) {
        vm.prank(orchestrator);
        return FeeRouter(payable(feeRouterFactory.create(playerId, pbrFeeHub)));
    }

    function _createPbrFeeHub(bytes32 leagueId, address leagueTreasury) internal returns (PbrFeeHub) {
        vm.prank(orchestrator);
        return PbrFeeHub(payable(pbrFeeHubFactory.create(leagueId, leagueTreasury)));
    }

    function _sendEth(address to, uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = to.call{ value: amount }("");
        require(ok, "eth send failed");
    }
}
