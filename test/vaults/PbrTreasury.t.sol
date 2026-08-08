// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Math } from "@openzeppelin/utils/math/Math.sol";

import { VaultsErrors as Errors } from "@errors/vaults/VaultsErrors.sol";
import { RoundStatus } from "@types/vaults/VaultTypes.sol";
import { PlayerVault } from "@vaults/PlayerVault.sol";
import { PbrTreasury } from "@vaults/PbrTreasury.sol";

import { VaultsTestBase } from "./VaultsTestBase.sol";
import { MockPlayerToken } from "./mocks/MockPlayerToken.sol";

contract PbrTreasuryTest is VaultsTestBase {
    PlayerVault internal vault;
    PlayerVault internal vault2;
    PbrTreasury internal treasury;

    uint64 internal startTime;
    uint64 internal endTime;

    function setUp() public override {
        super.setUp();
        (vault,) = _deployVault(PLAYER);
        (vault2,) = _deployVault(keccak256("player-2"));
        treasury = _deployTreasury(TOURNAMENT, START_YEAR);
        _registerVault(treasury, address(vault));

        startTime = uint64(block.timestamp + 1 days);
        endTime = uint64(block.timestamp + 8 days);
        _publishRound(TOURNAMENT, START_YEAR, 1, startTime, endTime, 10);
    }

    function test_receive_accruesRewards() public {
        _sendEth(address(treasury), 5 ether);
        assertEq(treasury.rewardsR(), 5 ether);
        assertEq(treasury.totalRewardsR(), 5 ether);

        _sendEth(address(treasury), 0);
        assertEq(treasury.rewardsR(), 5 ether);
    }

    function test_syncRegister_revertsUnauthorized() public {
        vm.expectRevert(Errors.Unauthorized.selector);
        treasury.syncRegisterVault(address(vault2));
    }

    function test_syncVaultStake_onStake() public {
        _stake(user, vault, 1 ether);
        address[] memory utilized = treasury.getUtilizedVaults(START_YEAR, 1);
        assertEq(utilized.length, 1);
        assertEq(utilized[0], address(vault));
    }

    function test_lockVaults_nonFinal_locks80Percent() public {
        _sendEth(address(treasury), 100 ether);
        vm.warp(startTime);
        _lockVaults(treasury);

        assertEq(treasury.getRound(START_YEAR, 1).R, 80 ether);
        assertEq(treasury.rewardsR(), 20 ether);
        assertEq(uint8(treasury.getRound(START_YEAR, 1).status), uint8(RoundStatus.Locked));
        assertEq(treasury.tradingRound(), 2);
        assertEq(treasury.getRound(START_YEAR, 1).lockBlock, uint64(block.number - 1));
    }

    function test_lockVaults_final_locks95Percent() public {
        _publishRound(TOURNAMENT, START_YEAR, 1, startTime, endTime, 1);
        _sendEth(address(treasury), 50 ether);
        vm.warp(startTime);
        _lockVaults(treasury);

        assertEq(treasury.getRound(START_YEAR, 1).R, 47.5 ether);
        assertEq(treasury.rewardsR(), 2.5 ether);
        assertEq(treasury.tradingRound(), 1);
    }

    function test_lockVaults_revertsBeforeStart() public {
        _sendEth(address(treasury), 1 ether);
        vm.expectRevert(Errors.NothingDue.selector);
        treasury.lockVaults();
    }

    function test_lockVaults_revertsWhenAlreadyLocked() public {
        _sendEth(address(treasury), 1 ether);
        vm.warp(startTime);
        _lockVaults(treasury);
        // After lock, tradingRound advances ahead of activeRound until settle opens Claimable.
        vm.expectRevert(Errors.NothingDue.selector);
        treasury.lockVaults();
    }

    function test_lockVaults_freezesUtilizedSet() public {
        _stake(user, vault, 1 ether);
        _sendEth(address(treasury), 10 ether);
        vm.warp(startTime);
        _lockVaults(treasury);

        _registerVault(treasury, address(vault2));
        _stake(user, vault2, 1 ether);

        // Mid-lock stake builds tradingRound utilized set, not the locked round.
        assertEq(treasury.getUtilizedVaults(START_YEAR, 1).length, 1);
        assertEq(treasury.getUtilizedVaults(START_YEAR, 1)[0], address(vault));
        assertEq(treasury.getUtilizedVaults(START_YEAR, 2).length, 1);
        assertEq(treasury.getUtilizedVaults(START_YEAR, 2)[0], address(vault2));
    }

    function test_settle_fixture_byPbrSettle() public {
        _stake(user, vault, 1 ether);
        _sendEth(address(treasury), 100 ether);
        vm.warp(startTime);
        _lockVaults(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 50;
        _settle(treasury, vaults, points);

        assertEq(uint8(treasury.getRound(START_YEAR, 1).status), uint8(RoundStatus.Claimable));
        assertEq(treasury.getVaultPoints(START_YEAR, 1, address(vault)), 50);
        assertEq(treasury.getRound(START_YEAR, 1).M_adj, 50);
        assertEq(treasury.activeRound(), 2);
        assertEq(tournamentRegistry.flushCount(), 1);
    }

    function test_settle_emptyUtilized_ok() public {
        _sendEth(address(treasury), 1 ether);
        vm.warp(startTime);
        _lockVaults(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](0);
        uint256[] memory points = new uint256[](0);
        _settle(treasury, vaults, points);

        assertEq(uint8(treasury.getRound(START_YEAR, 1).status), uint8(RoundStatus.Claimable));
        assertEq(treasury.getRound(START_YEAR, 1).M_adj, 0);
        assertEq(treasury.activeRound(), 2);
    }

    function test_requestSettle_revertsRoundNotEnded() public {
        _stake(user, vault, 1 ether);
        _sendEth(address(treasury), 1 ether);
        vm.warp(startTime);
        _lockVaults(treasury);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.RoundNotEnded.selector, START_YEAR, uint32(1), uint256(endTime), block.timestamp
            )
        );
        treasury.requestSettle();
    }

    function test_settle_finalRound_wrapsSeason() public {
        _publishRound(TOURNAMENT, START_YEAR, 1, startTime, endTime, 1);
        _stake(user, vault, 1 ether);
        _sendEth(address(treasury), 10 ether);
        vm.warp(startTime);
        _lockVaults(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 10;
        _settle(treasury, vaults, points);

        assertEq(treasury.seasonStartYear(), START_YEAR + 1);
        assertEq(treasury.activeRound(), 1);
    }

    function test_payClaim_pbrFormula() public {
        _stake(user, vault, 25 ether);
        _stake(user2, vault, 75 ether);

        _sendEth(address(treasury), 100 ether);
        vm.warp(startTime);
        _lockVaults(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 200;
        _settle(treasury, vaults, points);

        uint256 R = 80 ether;
        uint256 expectedUser = Math.mulDiv(Math.mulDiv(R, 200, 200), 25 ether, 100 ether);
        uint256 expectedUser2 = Math.mulDiv(Math.mulDiv(R, 200, 200), 75 ether, 100 ether);

        assertEq(treasury.previewClaim(START_YEAR, 1, address(vault), user), expectedUser);

        uint256 before = user.balance;
        vm.prank(user);
        uint256 payout = vault.claim(TOURNAMENT, START_YEAR, 1);
        assertEq(payout, expectedUser);
        assertEq(user.balance, before + expectedUser);

        before = user2.balance;
        vm.prank(user2);
        payout = vault.claim(TOURNAMENT, START_YEAR, 1);
        assertEq(payout, expectedUser2);
        assertEq(user2.balance, before + expectedUser2);
    }

    function test_payClaim_afterUnregister_stillWorks() public {
        _stake(user, vault, 10 ether);
        _sendEth(address(treasury), 100 ether);
        vm.warp(startTime);
        _lockVaults(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 100;
        _settle(treasury, vaults, points);

        vm.prank(address(tournamentRegistry));
        treasury.syncUnregisterVault(address(vault));
        assertFalse(treasury.isVault(address(vault)));

        vm.prank(user);
        uint256 payout = vault.claim(TOURNAMENT, START_YEAR, 1);
        assertEq(payout, 80 ether);
    }

    function test_payClaim_revertsUnknownVault_forEoa() public {
        _stake(user, vault, 10 ether);
        _sendEth(address(treasury), 100 ether);
        vm.warp(startTime);
        _lockVaults(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 100;
        _settle(treasury, vaults, points);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnknownVault.selector, user));
        treasury.payClaim(START_YEAR, 1, user);
    }

    function test_payClaim_transferFailed() public {
        ClaimRevertHelper helper = new ClaimRevertHelper();
        playerToken.mint(address(helper), 10 ether);
        helper.stake(vault, playerToken, 10 ether);

        _sendEth(address(treasury), 100 ether);
        vm.warp(startTime);
        _lockVaults(treasury);
        vm.warp(endTime);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        uint256[] memory points = new uint256[](1);
        points[0] = 100;
        _settle(treasury, vaults, points);

        vm.expectRevert(Errors.TransferFailed.selector);
        helper.claim(vault, TOURNAMENT, START_YEAR, 1);
    }

    function test_settle_twoFixtures_accumulates() public {
        bytes32[] memory fixtures = new bytes32[](2);
        fixtures[0] = keccak256("fx-a");
        fixtures[1] = keccak256("fx-b");
        tournamentRegistry.setFixtures(TOURNAMENT, START_YEAR, 1, fixtures);

        _stake(user, vault, 1 ether);
        _registerVault(treasury, address(vault2));
        _stake(user, vault2, 1 ether);
        _sendEth(address(treasury), 100 ether);
        vm.warp(startTime);
        _lockVaults(treasury);
        vm.warp(endTime);
        treasury.requestSettle();

        address[] memory v1 = new address[](1);
        v1[0] = address(vault);
        uint256[] memory p1 = new uint256[](1);
        p1[0] = 30;
        vm.prank(address(pbrSettle));
        bool done = treasury.applyFixtureSettlement(fixtures[0], keccak256("d1"), v1, p1);
        assertFalse(done);

        address[] memory v2 = new address[](1);
        v2[0] = address(vault2);
        uint256[] memory p2 = new uint256[](1);
        p2[0] = 70;
        vm.prank(address(pbrSettle));
        done = treasury.applyFixtureSettlement(fixtures[1], keccak256("d2"), v2, p2);
        assertTrue(done);

        assertEq(treasury.getVaultPoints(START_YEAR, 1, address(vault)), 30);
        assertEq(treasury.getVaultPoints(START_YEAR, 1, address(vault2)), 70);
        assertEq(treasury.getRound(START_YEAR, 1).M_adj, 100);
    }
}

contract ClaimRevertHelper {
    receive() external payable {
        revert("no eth");
    }

    function stake(PlayerVault vault, MockPlayerToken token, uint256 amount) external {
        token.approve(address(vault), amount);
        vault.stake(amount);
    }

    function claim(PlayerVault vault, bytes32 tournamentId, uint16 seasonStartYear, uint32 round) external {
        vault.claim(tournamentId, seasonStartYear, round);
    }
}
