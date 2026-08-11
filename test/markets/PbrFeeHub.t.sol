// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { MarketsErrors as Errors } from "@errors/markets/MarketsErrors.sol";
import { MarketsEvents as Events } from "@events/markets/MarketsEvents.sol";
import { PbrFeeHub } from "@markets/PbrFeeHub.sol";
import { TournamentType } from "@types/registries/TournamentTypes.sol";

import { MarketsTestBase } from "./MarketsTestBase.sol";
import { AcceptingReceiver, RevertingReceiver, ToggleReceiver } from "./mocks/ETHReceivers.sol";

contract PbrFeeHubTest is MarketsTestBase {
    bytes32 internal constant LEAGUE = keccak256("league-1");

    AcceptingReceiver internal leagueTreasury;
    PbrFeeHub internal hub;

    function setUp() public override {
        super.setUp();
        leagueTreasury = new AcceptingReceiver();
        hub = _createPbrFeeHub(LEAGUE, address(leagueTreasury));
    }

    // --------------------------------------------
    //  Defaults / cascade
    // --------------------------------------------

    function test_receive_defaults_allToLeagueWhenBucketsEmpty() public {
        _sendEth(address(hub), 100 ether);
        // Empty continental/intl → domestic engulfs 100%; no cups → 100% league.
        assertEq(address(leagueTreasury).balance, 100 ether);
        assertEq(address(hub).balance, 0);
    }

    function test_receive_cascade_liveBucketsTakeBps_domesticEngulfs() public {
        AcceptingReceiver continental = new AcceptingReceiver();
        AcceptingReceiver intl = new AcceptingReceiver();

        address[] memory cont = new address[](1);
        cont[0] = address(continental);
        address[] memory international = new address[](1);
        international[0] = address(intl);

        vm.startPrank(address(tournamentRegistry));
        hub.setContinental(cont);
        hub.setInternational(international);
        vm.stopPrank();

        _sendEth(address(hub), 100 ether);

        // 9% continental, 1% international, 90% domestic → league
        assertEq(address(continental).balance, 9 ether);
        assertEq(address(intl).balance, 1 ether);
        assertEq(address(leagueTreasury).balance, 90 ether);
    }

    function test_receive_emptyContinental_domesticEngulfsContinentalShare() public {
        AcceptingReceiver intl = new AcceptingReceiver();
        address[] memory international = new address[](1);
        international[0] = address(intl);

        vm.prank(address(tournamentRegistry));
        hub.setInternational(international);

        _sendEth(address(hub), 100 ether);

        // continental empty → its 9% engulfs into domestic; intl takes 1%
        assertEq(address(intl).balance, 1 ether);
        assertEq(address(leagueTreasury).balance, 99 ether);
    }

    // --------------------------------------------
    //  Cups sub-split
    // --------------------------------------------

    function test_receive_cups_leagueShareAndEvenRemainder() public {
        AcceptingReceiver cupA = new AcceptingReceiver();
        AcceptingReceiver cupB = new AcceptingReceiver();
        address[] memory cups = new address[](2);
        cups[0] = address(cupA);
        cups[1] = address(cupB);

        vm.prank(address(tournamentRegistry));
        hub.setDomesticCups(cups);

        _sendEth(address(hub), 100 ether);

        // leagueShareBps = 8900 → 89 ether league; 11 ether even across 2 cups
        assertEq(address(leagueTreasury).balance, 89 ether);
        assertEq(address(cupA).balance, 5.5 ether);
        assertEq(address(cupB).balance, 5.5 ether);
    }

    function test_receive_cups_lastLegDust() public {
        AcceptingReceiver cupA = new AcceptingReceiver();
        AcceptingReceiver cupB = new AcceptingReceiver();
        address[] memory cups = new address[](2);
        cups[0] = address(cupA);
        cups[1] = address(cupB);

        vm.prank(address(tournamentRegistry));
        hub.setDomesticCups(cups);
        vm.prank(timelock);
        hub.setLeagueShareBps(8900);

        uint256 amount = 101; // tiny amount to force dust on cup remainder
        _sendEth(address(hub), amount);

        uint256 leagueAmt = (amount * 8900) / BPS;
        uint256 cupsAmt = amount - leagueAmt;
        uint256 share = cupsAmt / 2;
        uint256 last = cupsAmt - share;

        assertEq(address(leagueTreasury).balance, leagueAmt);
        assertEq(address(cupA).balance, share);
        assertEq(address(cupB).balance, last);
    }

    // --------------------------------------------
    //  International active override
    // --------------------------------------------

    function test_internationalActive_takesGrossShareThenCascade() public {
        AcceptingReceiver intlActive = new AcceptingReceiver();
        _wireInternational(address(intlActive));

        vm.prank(timelock);
        hub.setInternationalActive(true, address(intlActive));

        _sendEth(address(hub), 100 ether);

        // 90% override → intl; of remaining 10%, cascade intl bps (1%) → 0.1; domestic engulfs 9.9
        assertEq(address(intlActive).balance, 90.1 ether);
        assertEq(address(leagueTreasury).balance, 9.9 ether);
    }

    function test_internationalActive_deactivateClearsTreasury() public {
        AcceptingReceiver intlActive = new AcceptingReceiver();
        _wireInternational(address(intlActive));

        vm.startPrank(timelock);
        hub.setInternationalActive(true, address(intlActive));
        hub.setInternationalActive(false, address(0));
        vm.stopPrank();

        assertFalse(hub.internationalActive());
        assertEq(hub.internationalActiveTreasury(), address(0));

        _sendEth(address(hub), 100 ether);
        // override off; live intl still takes 1%
        assertEq(address(intlActive).balance, 1 ether);
        assertEq(address(leagueTreasury).balance, 99 ether);
    }

    function test_internationalActive_misconfiguredReverts() public {
        vm.prank(timelock);
        vm.expectRevert(Errors.ZeroAddress.selector);
        hub.setInternationalActive(true, address(0));
    }

    function test_internationalActive_revertsUnknownTreasury() public {
        AcceptingReceiver unknown = new AcceptingReceiver();
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(Errors.TreasuryNotInternational.selector, address(unknown)));
        hub.setInternationalActive(true, address(unknown));
    }

    function test_internationalActive_zeroTreasuryWhileActive_revertsOnReceive() public {
        InternationalMisconfigHarness harness = new InternationalMisconfigHarness(address(ap));
        harness.forceActiveWithoutTreasury();

        vm.expectRevert(Errors.InternationalNotConfigured.selector);
        _sendEth(address(harness), 1 ether);
    }

    // --------------------------------------------
    //  Pending / forward
    // --------------------------------------------

    function test_revertingTreasury_accruesPending_forwardDrains() public {
        ToggleReceiver toggling = new ToggleReceiver();
        toggling.setAccept(false);
        PbrFeeHub togglingHub = _createPbrFeeHub(keccak256("league-toggle"), address(toggling));

        vm.expectEmit(true, true, false, true, address(togglingHub));
        emit Events.FeesQueued(TournamentType.DOMESTIC_LEAGUE, address(toggling), 100 ether);

        _sendEth(address(togglingHub), 100 ether);

        assertEq(togglingHub.pending(address(toggling)), 100 ether);
        assertEq(address(togglingHub).balance, 100 ether);

        toggling.setAccept(true);
        togglingHub.forward();

        assertEq(togglingHub.pending(address(toggling)), 0);
        assertEq(address(toggling).balance, 100 ether);
        assertEq(address(togglingHub).balance, 0);
    }

    function test_forwardPending_orphanPath() public {
        ToggleReceiver orphan = new ToggleReceiver();
        orphan.setAccept(false);

        address[] memory cups = new address[](1);
        cups[0] = address(orphan);
        vm.prank(address(tournamentRegistry));
        hub.setDomesticCups(cups);

        _sendEth(address(hub), 100 ether);
        // 11% cups bucket → orphan queues; league takes 89%
        assertEq(hub.pending(address(orphan)), 11 ether);

        // Drop orphan from configured destinations so `forward` won't target it.
        vm.prank(address(tournamentRegistry));
        hub.setDomesticCups(new address[](0));

        orphan.setAccept(true);
        vm.expectEmit(true, false, false, true, address(hub));
        emit Events.OrphanFeesRelayed(address(orphan), 11 ether);
        hub.forwardPending(address(orphan));

        assertEq(hub.pending(address(orphan)), 0);
        assertEq(address(orphan).balance, 11 ether);
    }

    function test_forwardPending_stillReverting_requeues() public {
        RevertingReceiver bad = new RevertingReceiver();
        address[] memory cups = new address[](1);
        cups[0] = address(bad);
        vm.prank(address(tournamentRegistry));
        hub.setDomesticCups(cups);

        _sendEth(address(hub), 100 ether);
        uint256 queued = hub.pending(address(bad));
        assertTrue(queued > 0);

        vm.expectEmit(true, false, false, true, address(hub));
        emit Events.OrphanFeesQueued(address(bad), queued);
        hub.forwardPending(address(bad));
        assertEq(hub.pending(address(bad)), queued);
    }

    // --------------------------------------------
    //  Hard reverts / admin
    // --------------------------------------------

    function test_setTopLevelSplit_revertsBadTotal() public {
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidBpsTotal.selector, 9999));
        hub.setTopLevelSplit(9000, 900, 99);
    }

    function test_setDomesticCups_revertsDuplicate() public {
        AcceptingReceiver cup = new AcceptingReceiver();
        address[] memory cups = new address[](2);
        cups[0] = address(cup);
        cups[1] = address(cup);

        vm.prank(address(tournamentRegistry));
        vm.expectRevert(abi.encodeWithSelector(Errors.DuplicateTreasury.selector, address(cup)));
        hub.setDomesticCups(cups);
    }

    function test_setDomesticCups_revertsZero() public {
        address[] memory cups = new address[](1);
        cups[0] = address(0);
        vm.prank(address(tournamentRegistry));
        vm.expectRevert(Errors.ZeroAddress.selector);
        hub.setDomesticCups(cups);
    }

    function test_setLeagueShareBps_revertsAboveDenom() public {
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidBpsTotal.selector, 10_001));
        hub.setLeagueShareBps(10_001);
    }

    function test_admin_revertsUnauthorized() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(Errors.Unauthorized.selector);
        hub.setTopLevelSplit(9000, 900, 100);

        address[] memory cups = new address[](0);
        vm.prank(stranger);
        vm.expectRevert(Errors.Unauthorized.selector);
        hub.setDomesticCups(cups);
    }

    function test_forwardPending_revertsZero() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        hub.forwardPending(address(0));
    }

    function test_setInternationalActiveShareBps() public {
        vm.prank(timelock);
        hub.setInternationalActiveShareBps(5000);
        assertEq(hub.internationalActiveShareBps(), 5000);

        AcceptingReceiver intlActive = new AcceptingReceiver();
        _wireInternational(address(intlActive));
        vm.prank(timelock);
        hub.setInternationalActive(true, address(intlActive));

        _sendEth(address(hub), 100 ether);
        // 50% override; of remaining 50%, intl cascade 1% → 0.5; domestic 49.5
        assertEq(address(intlActive).balance, 50.5 ether);
        assertEq(address(leagueTreasury).balance, 49.5 ether);
    }

    function _wireInternational(address treasury) internal {
        address[] memory intl = new address[](1);
        intl[0] = treasury;
        vm.prank(address(tournamentRegistry));
        hub.setInternational(intl);
    }

    function test_continentalEvenSplit() public {
        AcceptingReceiver c1 = new AcceptingReceiver();
        AcceptingReceiver c2 = new AcceptingReceiver();
        address[] memory cont = new address[](2);
        cont[0] = address(c1);
        cont[1] = address(c2);

        vm.prank(address(tournamentRegistry));
        hub.setContinental(cont);

        _sendEth(address(hub), 100 ether);
        // 9 ether continental even → 4.5 each; 91 engulfs to league (intl empty)
        assertEq(address(c1).balance, 4.5 ether);
        assertEq(address(c2).balance, 4.5 ether);
        assertEq(address(leagueTreasury).balance, 91 ether);
    }
}

/// @dev Harness to force `internationalActive` with a zero treasury for revert coverage.
contract InternationalMisconfigHarness is PbrFeeHub {
    constructor(address ap) PbrFeeHub(ap) {
        // Bypass initializer disable for test harness by calling initialize-equivalent storage.
    }

    function forceActiveWithoutTreasury() external {
        // Initialize-like fields needed for receive → _split.
        leagueTreasury = address(1); // non-zero so cascade wouldn't be the failure mode
        domesticBps = 9000;
        continentalBps = 900;
        internationalBps = 100;
        leagueShareBps = 8900;
        internationalActiveShareBps = 9000;
        internationalActive = true;
        internationalActiveTreasury = address(0);
    }
}
