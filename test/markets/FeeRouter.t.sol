// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";

import { MarketsErrors as Errors } from "@errors/markets/MarketsErrors.sol";
import { MarketsEvents as Events } from "@events/markets/MarketsEvents.sol";
import { FeeRouter } from "@markets/FeeRouter.sol";
import { PlayerStatus } from "@types/registries/PlayerSetTypes.sol";

import { MarketsTestBase } from "./MarketsTestBase.sol";
import {
    AcceptingReceiver,
    MockERC20,
    RevertingReceiver,
    ToggleReceiver
} from "./mocks/ETHReceivers.sol";

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
    //  Integrator / redistribution splits
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
        vm.prank(orchestrator);
        router.setStatus(PlayerStatus.GRADUATED);

        _sendEth(address(router), 95 ether);

        assertEq(address(hpTreasury).balance, 5 ether);
        assertEq(address(hub).balance, 90 ether);
        assertEq(router.integratorShareNum(), 5);
    }

    function test_setRedistribution_multiHub_lastLegDust() public {
        AcceptingReceiver hub2 = new AcceptingReceiver();

        address[] memory hubs = new address[](2);
        hubs[0] = address(hub);
        hubs[1] = address(hub2);
        uint256[] memory splits = new uint256[](2);
        splits[0] = 6e17;
        splits[1] = 4e17;

        vm.prank(orchestrator);
        router.setRedistribution(hubs, splits);

        // Use amount that leaves dust on integer division of first leg.
        uint256 amount = 95 ether + 1; // integrator = floor((95e18+1)*10/95)
        _sendEth(address(router), amount);

        uint256 integratorAmt = (amount * 10) / 95;
        uint256 remainder = amount - integratorAmt;
        uint256 leg0 = (remainder * 6e17) / WAD;
        uint256 leg1 = remainder - leg0;

        assertEq(address(hpTreasury).balance, integratorAmt);
        assertEq(address(hub).balance, leg0);
        assertEq(address(hub2).balance, leg1);
        assertEq(address(router).balance, 0);
    }

    // --------------------------------------------
    //  OOF / INACTIVE
    // --------------------------------------------

    function test_inactive_ignoresStoredHubs_evenSplitsDomestics() public {
        AcceptingReceiver domesticA = new AcceptingReceiver();
        AcceptingReceiver domesticB = new AcceptingReceiver();
        address[] memory domestics = new address[](2);
        domestics[0] = address(domesticA);
        domestics[1] = address(domesticB);
        tournamentRegistry.setDomesticPbrFeeHubs(domestics);

        // Hub storage must persist across deactivate.
        address[] memory beforeHubs = router.redistributionHubs();
        assertEq(beforeHubs.length, 1);
        assertEq(router.pbrFeeHub(), address(hub));

        vm.prank(orchestrator);
        router.setStatus(PlayerStatus.INACTIVE);

        assertEq(router.pbrFeeHub(), address(hub));
        assertEq(router.redistributionHubs().length, 1);
        assertEq(router.redistributionHubs()[0], address(hub));

        _sendEth(address(router), 95 ether);

        // Spot integrator 5/95; remainder even across domestics (not stored hub).
        assertEq(address(hpTreasury).balance, 5 ether);
        assertEq(address(hub).balance, 0);
        assertEq(address(domesticA).balance, 45 ether);
        assertEq(address(domesticB).balance, 45 ether);
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

        vm.prank(orchestrator);
        router.setPbrFeeHub(address(0));

        assertEq(router.pbrFeeHub(), address(0));
        assertEq(router.redistributionHubs().length, 0);

        _sendEth(address(router), 95 ether);
        assertEq(address(domestic).balance, 85 ether);
        assertEq(address(hub).balance, 0);
    }

    // --------------------------------------------
    //  Soft fail / forward
    // --------------------------------------------

    function test_revertingHub_queuesAndForwardRetries() public {
        RevertingReceiver badHub = new RevertingReceiver();
        vm.prank(orchestrator);
        router.setPbrFeeHub(address(badHub));

        _sendEth(address(router), 95 ether);

        assertEq(address(hpTreasury).balance, 10 ether);
        assertEq(address(router).balance, 85 ether);

        // Swap to accepting hub. setPbrFeeHub sweeps via _relay, which re-applies the
        // bonding integrator cut on the residual balance.
        AcceptingReceiver goodHub = new AcceptingReceiver();
        uint256 residual = address(router).balance;
        uint256 integratorCut = (residual * 10) / 95;
        uint256 hubCut = residual - integratorCut;

        uint256 integratorBefore = address(hpTreasury).balance;
        vm.prank(orchestrator);
        router.setPbrFeeHub(address(goodHub));

        assertEq(address(hpTreasury).balance, integratorBefore + integratorCut);
        assertEq(address(goodHub).balance, hubCut);
        assertEq(address(router).balance, 0);
    }

    function test_revertingIntegrator_queuesThenForward() public {
        RevertingReceiver badIntegrator = new RevertingReceiver();
        vm.prank(orchestrator);
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

        vm.prank(orchestrator);
        router.setIntegrator(address(goodIntegrator));

        assertEq(address(goodIntegrator).balance, integratorCut);
        assertEq(address(hub).balance, hubBefore + hubCut);
        assertEq(address(router).balance, 0);
    }

    function test_forward_bypassesMinRelay() public {
        uint256 dust = 0.00005 ether;
        _sendEth(address(router), dust);
        assertEq(address(router).balance, dust);

        router.forward();
        uint256 integratorAmt = (dust * 10) / 95;
        assertEq(address(hpTreasury).balance, integratorAmt);
        assertEq(address(hub).balance, dust - integratorAmt);
        assertEq(address(router).balance, 0);
    }

    // --------------------------------------------
    //  minRelay
    // --------------------------------------------

    function test_receive_belowMinRelay_holds() public {
        _sendEth(address(router), 0.00005 ether);
        assertEq(address(router).balance, 0.00005 ether);
        assertEq(address(hpTreasury).balance, 0);
        assertEq(address(hub).balance, 0);
    }

    function test_setMinRelay_triggersRelay() public {
        _sendEth(address(router), 0.00005 ether);
        assertEq(address(router).balance, 0.00005 ether);

        vm.prank(orchestrator);
        router.setMinRelay(0.00005 ether);

        assertEq(address(router).balance, 0);
        assertTrue(address(hpTreasury).balance > 0);
        assertTrue(address(hub).balance > 0);
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
        vm.prank(playerSetRegistry);
        router.setPbrFeeHub(address(next));
        assertEq(router.pbrFeeHub(), address(next));
    }

    function test_setStatus_revertsUnauthorized() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.Unauthorized.selector);
        router.setStatus(PlayerStatus.GRADUATED);
    }

    function test_setMinRelay_revertsNonOwner() public {
        vm.prank(playerSetRegistry);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, playerSetRegistry));
        router.setMinRelay(1);
    }

    function test_setRedistribution_revertsNonOwner() public {
        address[] memory hubs = new address[](1);
        hubs[0] = address(hub);
        uint256[] memory splits = new uint256[](1);
        splits[0] = WAD;

        vm.prank(playerSetRegistry);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, playerSetRegistry));
        router.setRedistribution(hubs, splits);
    }

    // --------------------------------------------
    //  Config edges
    // --------------------------------------------

    function test_setRedistribution_revertsWhenHubCleared() public {
        vm.prank(orchestrator);
        router.setPbrFeeHub(address(0));

        address[] memory hubs = new address[](1);
        hubs[0] = address(hub);
        uint256[] memory splits = new uint256[](1);
        splits[0] = WAD;

        vm.prank(orchestrator);
        vm.expectRevert(Errors.PbrFeeHubRequired.selector);
        router.setRedistribution(hubs, splits);
    }

    function test_setRedistribution_revertsMissingPbrHub() public {
        AcceptingReceiver other = new AcceptingReceiver();
        address[] memory hubs = new address[](1);
        hubs[0] = address(other);
        uint256[] memory splits = new uint256[](1);
        splits[0] = WAD;

        vm.prank(orchestrator);
        vm.expectRevert(abi.encodeWithSelector(Errors.PbrFeeHubMissing.selector, address(hub)));
        router.setRedistribution(hubs, splits);
    }

    function test_setRedistribution_revertsDuplicate() public {
        address[] memory hubs = new address[](2);
        hubs[0] = address(hub);
        hubs[1] = address(hub);
        uint256[] memory splits = new uint256[](2);
        splits[0] = 5e17;
        splits[1] = 5e17;

        vm.prank(orchestrator);
        vm.expectRevert(abi.encodeWithSelector(Errors.DuplicateRedistributionHub.selector, address(hub)));
        router.setRedistribution(hubs, splits);
    }

    function test_setRedistribution_revertsBadTotal() public {
        address[] memory hubs = new address[](1);
        hubs[0] = address(hub);
        uint256[] memory splits = new uint256[](1);
        splits[0] = WAD - 1;

        vm.prank(orchestrator);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidFeeSplitTotal.selector, WAD - 1));
        router.setRedistribution(hubs, splits);
    }

    function test_setPbrFeeHub_revertsEoa() public {
        vm.prank(orchestrator);
        vm.expectRevert(Errors.DestinationNotContract.selector);
        router.setPbrFeeHub(makeAddr("eoa-hub"));
    }

    function test_setIntegrator_revertsZero() public {
        vm.prank(orchestrator);
        vm.expectRevert(Errors.ZeroAddress.selector);
        router.setIntegrator(address(0));
    }

    function test_rescueToken() public {
        MockERC20 token = new MockERC20();
        token.mint(address(router), 100);
        address to = makeAddr("rescue-to");

        vm.prank(orchestrator);
        router.rescueToken(address(token), to, 100);
        assertEq(token.balanceOf(to), 100);
    }

    function test_setStatus_sameStatus_noop() public {
        uint256 balBefore = address(hub).balance;
        vm.prank(orchestrator);
        router.setStatus(PlayerStatus.BONDING);
        assertEq(address(hub).balance, balBefore);
    }

    function test_toggleReceiver_softQueueThenForward() public {
        ToggleReceiver toggleHub = new ToggleReceiver();
        toggleHub.setAccept(false);

        vm.prank(orchestrator);
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
