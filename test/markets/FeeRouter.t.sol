// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { MarketsErrors as Errors } from "@errors/markets/MarketsErrors.sol";
import { MarketsEvents as Events } from "@events/markets/MarketsEvents.sol";
import { FeeRouter } from "@markets/FeeRouter.sol";
import { PlayerStatus } from "@types/registries/PlayerSetTypes.sol";

import { MarketsTestBase } from "./MarketsTestBase.sol";
import { AcceptingReceiver, RevertingReceiver, ToggleReceiver } from "./mocks/ETHReceivers.sol";

contract FeeRouterTest is MarketsTestBase {
    bytes32 internal constant PLAYER = keccak256("player-1");

    AcceptingReceiver internal hub;
    FeeRouter internal router;

    function setUp() public override {
        super.setUp();
        hub = new AcceptingReceiver();
        router = _createFeeRouter(PLAYER, address(hub));
    }

    // --------------------------------------------
    //  Integrator / league hub
    // --------------------------------------------

    function test_receive_bonding_splitsIntegratorAndHub() public {
        uint256 amount = 95 ether;
        _sendEth(address(router), amount);

        // Bonding: 10/95 integrator, 85 remainder → hub
        assertEq(address(hpTreasury).balance, 10 ether);
        assertEq(address(hub).balance, 85 ether);
        assertEq(address(router).balance, 0);
    }

    function test_receive_graduated_usesSpotIntegratorShare() public {
        vm.prank(playerSetRegistry);
        router.setStatus(PlayerStatus.GRADUATED);

        _sendEth(address(router), 95 ether);

        assertEq(address(hpTreasury).balance, 5 ether);
        assertEq(address(hub).balance, 90 ether);
        assertEq(router.integratorShareNum(), 5);
    }

    // --------------------------------------------
    //  OOF / INACTIVE
    // --------------------------------------------

    function test_inactive_evenSplitsDomestics_keepsStoredHub() public {
        AcceptingReceiver domesticA = new AcceptingReceiver();
        AcceptingReceiver domesticB = new AcceptingReceiver();
        address[] memory domestics = new address[](2);
        domestics[0] = address(domesticA);
        domestics[1] = address(domesticB);
        tournamentRegistry.setDomesticPbrFeeHubs(domestics);

        assertEq(router.pbrFeeHub(), address(hub));

        vm.prank(playerSetRegistry);
        router.setStatus(PlayerStatus.INACTIVE);

        // Stored league hub persists for reactivate / transfer restore.
        assertEq(router.pbrFeeHub(), address(hub));

        _sendEth(address(router), 95 ether);

        // Inactive: no integrator cut; full balance even across domestics (not stored hub).
        assertEq(address(hpTreasury).balance, 0);
        assertEq(address(hub).balance, 0);
        assertEq(address(domesticA).balance, 47.5 ether);
        assertEq(address(domesticB).balance, 47.5 ether);
        assertEq(router.integratorShareNum(), 0);
    }

    function test_zeroHub_usesOofPath() public {
        FeeRouter unsupported = _createFeeRouter(keccak256("unsupported"), address(0));
        AcceptingReceiver domestic = new AcceptingReceiver();
        address[] memory domestics = new address[](1);
        domestics[0] = address(domestic);
        tournamentRegistry.setDomesticPbrFeeHubs(domestics);

        _sendEth(address(unsupported), 95 ether);

        assertEq(address(hpTreasury).balance, 10 ether);
        assertEq(address(domestic).balance, 85 ether);
    }

    function test_oof_emptyDomestics_queuesRemainder() public {
        // Clear hubs registered in setUp so OOF has nowhere to send.
        tournamentRegistry.setDomesticPbrFeeHubs(new address[](0));

        FeeRouter unsupported = _createFeeRouter(keccak256("oof-empty"), address(0));

        vm.expectEmit(true, true, false, true, address(unsupported));
        emit Events.FeesQueued(keccak256("oof-empty"), address(0), 85 ether);

        _sendEth(address(unsupported), 95 ether);

        assertEq(address(hpTreasury).balance, 10 ether);
        assertEq(address(unsupported).balance, 85 ether);
    }

    function test_clearHub_enablesOof() public {
        AcceptingReceiver domestic = new AcceptingReceiver();
        address[] memory domestics = new address[](1);
        domestics[0] = address(domestic);
        tournamentRegistry.setDomesticPbrFeeHubs(domestics);

        vm.prank(playerSetRegistry);
        router.setPbrFeeHub(address(0));

        assertEq(router.pbrFeeHub(), address(0));

        _sendEth(address(router), 95 ether);
        assertEq(address(domestic).balance, 85 ether);
        assertEq(address(hub).balance, 0);
    }

    // --------------------------------------------
    //  Soft fail / forward
    // --------------------------------------------

    function test_revertingHub_queuesAndForwardRetries() public {
        RevertingReceiver badHub = new RevertingReceiver();
        tournamentRegistry.registerDomesticHub(address(badHub));
        vm.prank(playerSetRegistry);
        router.setPbrFeeHub(address(badHub));

        _sendEth(address(router), 95 ether);

        assertEq(address(hpTreasury).balance, 10 ether);
        assertEq(address(router).balance, 85 ether);

        // Swap to accepting hub. setPbrFeeHub sweeps via _relay, which re-applies the
        // bonding integrator cut on the residual balance.
        AcceptingReceiver goodHub = new AcceptingReceiver();
        tournamentRegistry.registerDomesticHub(address(goodHub));
        uint256 residual = address(router).balance;
        uint256 integratorCut = (residual * 10) / 95;
        uint256 hubCut = residual - integratorCut;

        uint256 integratorBefore = address(hpTreasury).balance;
        vm.prank(playerSetRegistry);
        router.setPbrFeeHub(address(goodHub));

        assertEq(address(hpTreasury).balance, integratorBefore + integratorCut);
        assertEq(address(goodHub).balance, hubCut);
        assertEq(address(router).balance, 0);
    }

    function test_revertingIntegrator_queuesThenForward() public {
        RevertingReceiver badIntegrator = new RevertingReceiver();
        vm.prank(timelock);
        router.setIntegrator(address(badIntegrator));

        _sendEth(address(router), 95 ether);
        // Failed integrator leg leaves its cut on the router; hub still receives remainder.
        assertEq(address(hub).balance, 85 ether);
        assertEq(address(router).balance, 10 ether);

        AcceptingReceiver goodIntegrator = new AcceptingReceiver();
        uint256 residual = address(router).balance;
        uint256 integratorCut = (residual * 10) / 95;
        uint256 hubCut = residual - integratorCut;
        uint256 hubBefore = address(hub).balance;

        vm.prank(timelock);
        router.setIntegrator(address(goodIntegrator));

        assertEq(address(goodIntegrator).balance, integratorCut);
        assertEq(address(hub).balance, hubBefore + hubCut);
        assertEq(address(router).balance, 0);
    }

    function test_forward_bypassesMinRelay() public {
        uint256 dust = 0.000_05 ether;
        _sendEth(address(router), dust);
        assertEq(address(router).balance, dust);

        router.forward();
        uint256 integratorAmt = (dust * 10) / 95;
        assertEq(address(hpTreasury).balance, integratorAmt);
        assertEq(address(hub).balance, dust - integratorAmt);
        assertEq(address(router).balance, 0);
    }

    // --------------------------------------------
    //  minRelay hold
    // --------------------------------------------

    function test_receive_belowMinRelay_holds() public {
        _sendEth(address(router), 0.000_05 ether);
        assertEq(address(router).balance, 0.000_05 ether);
        assertEq(address(hpTreasury).balance, 0);
        assertEq(address(hub).balance, 0);
    }

    // --------------------------------------------
    //  Access control
    // --------------------------------------------

    function test_setStatus_allowsPlayerSetRegistry() public {
        vm.prank(playerSetRegistry);
        router.setStatus(PlayerStatus.GRADUATED);
        assertEq(uint8(router.status()), uint8(PlayerStatus.GRADUATED));
    }

    function test_setPbrFeeHub_allowsPlayerSetRegistry() public {
        AcceptingReceiver next = new AcceptingReceiver();
        tournamentRegistry.registerDomesticHub(address(next));
        vm.prank(playerSetRegistry);
        router.setPbrFeeHub(address(next));
        assertEq(router.pbrFeeHub(), address(next));
    }

    function test_setPbrFeeHub_revertsUnregisteredHub() public {
        AcceptingReceiver unknown = new AcceptingReceiver();
        vm.prank(playerSetRegistry);
        vm.expectRevert(abi.encodeWithSelector(Errors.PbrFeeHubNotRegistered.selector, address(unknown)));
        router.setPbrFeeHub(address(unknown));
    }

    function test_setStatus_revertsUnauthorized() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.Unauthorized.selector);
        router.setStatus(PlayerStatus.GRADUATED);
    }

    function test_setPbrFeeHub_revertsUnauthorized() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.Unauthorized.selector);
        router.setPbrFeeHub(address(hub));
    }

    function test_setIntegrator_revertsUnauthorized() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.Unauthorized.selector);
        router.setIntegrator(address(hub));
    }

    // --------------------------------------------
    //  Config edges
    // --------------------------------------------

    function test_setPbrFeeHub_revertsEoa() public {
        vm.prank(playerSetRegistry);
        vm.expectRevert(Errors.DestinationNotContract.selector);
        router.setPbrFeeHub(makeAddr("eoa-hub"));
    }

    function test_setIntegrator_revertsZero() public {
        vm.prank(timelock);
        vm.expectRevert(Errors.ZeroAddress.selector);
        router.setIntegrator(address(0));
    }

    function test_setStatus_sameStatus_noop() public {
        uint256 balBefore = address(hub).balance;
        vm.prank(playerSetRegistry);
        router.setStatus(PlayerStatus.BONDING);
        assertEq(address(hub).balance, balBefore);
    }

    function test_toggleReceiver_softQueueThenForward() public {
        ToggleReceiver toggleHub = new ToggleReceiver();
        toggleHub.setAccept(false);
        tournamentRegistry.registerDomesticHub(address(toggleHub));

        vm.prank(playerSetRegistry);
        router.setPbrFeeHub(address(toggleHub));

        _sendEth(address(router), 95 ether);
        assertEq(address(router).balance, 85 ether);

        // forward() re-applies bonding integrator cut on residual.
        uint256 residual = address(router).balance;
        uint256 integratorCut = (residual * 10) / 95;
        uint256 hubCut = residual - integratorCut;
        uint256 integratorBefore = address(hpTreasury).balance;

        toggleHub.setAccept(true);
        router.forward();

        assertEq(address(hpTreasury).balance, integratorBefore + integratorCut);
        assertEq(address(toggleHub).balance, hubCut);
        assertEq(address(router).balance, 0);
    }
}
