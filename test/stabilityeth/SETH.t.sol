// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import { AppRegistry } from "@stabilityeth/AppRegistry.sol";
import { Minter } from "@stabilityeth/Minter.sol";
import { MinterFactory } from "@stabilityeth/factories/MinterFactory.sol";
import { PBRTreasury } from "@stabilityeth/PBRTreasury.sol";
import { SETH } from "@stabilityeth/SETH.sol";
import { MockTvlContract } from "./MockTvlContract.sol";

contract SETHTest is Test {
    address internal owner = makeAddr("owner");
    address internal rootDeployer = makeAddr("rootDeployer");
    address internal user = makeAddr("user");
    address internal beneficiary = makeAddr("beneficiary");
    address internal forwarder = makeAddr("forwarder");

    bytes32 internal constant WORKFLOW_ID = keccak256("seth-pbr-v1");

    SETH internal seth;
    MinterFactory internal factory;
    AppRegistry internal registry;
    PBRTreasury internal treasury;
    Minter internal minter;
    bytes32 internal appId;

    function setUp() public {
        seth = new SETH(owner);
        factory = new MinterFactory(address(seth), owner, owner);
        registry = new AppRegistry(address(seth), address(factory), owner);

        PBRTreasury impl = new PBRTreasury();
        bytes memory initData = abi.encodeCall(
            PBRTreasury.initialize, (owner, address(seth), address(registry), forwarder, WORKFLOW_ID)
        );
        treasury = PBRTreasury(payable(address(new ERC1967Proxy(address(impl), initData))));

        vm.startPrank(owner);
        factory.setRegistry(address(registry));
        seth.setMinterManager(address(registry));
        seth.setFeeCollector(address(treasury));
        registry.setPbrTreasury(address(treasury));
        vm.stopPrank();

        address[] memory tvl = new address[](1);
        tvl[0] = address(new MockTvlContract(rootDeployer));

        vm.prank(owner);
        address minterAddr;
        (appId, minterAddr) = registry.register(rootDeployer, tvl);
        minter = Minter(payable(minterAddr));
    }

    function test_directDeposit_skimsFeeAndMintsNet() public {
        uint256 ethIn = 1 ether;
        vm.deal(user, ethIn);

        vm.prank(user);
        seth.deposit{ value: ethIn }();

        uint256 fee = ethIn / 1000; // 0.1%
        uint256 net = ethIn - fee;
        assertEq(seth.balanceOf(user), net * 100);
        assertEq(seth.feeAccrued(), fee);
        assertEq(seth.totalMinterMinted(), 0);
        assertTrue(seth.isFullyBacked());
    }

    function test_minterDeposit_creditsAppTotalMinted() public {
        uint256 ethIn = 1 ether;
        vm.deal(user, ethIn);

        vm.prank(user);
        minter.deposit{ value: ethIn }();

        uint256 fee = ethIn / 1000;
        uint256 expectedSeth = (ethIn - fee) * 100;

        assertEq(seth.balanceOf(user), expectedSeth);
        assertEq(minter.totalMinted(), expectedSeth);
        assertEq(registry.totalMinted(appId), expectedSeth);
        assertEq(registry.netMinted(appId), expectedSeth);
        assertEq(seth.totalMinterMinted(), expectedSeth);
        assertEq(minter.appId(), appId);
        assertEq(registry.appIdOfMinter(address(minter)), appId);
        assertEq(seth.feeAccrued(), fee);
    }

    function test_minterWithdraw_skimsFeeDoesNotReduceTotalMinted() public {
        uint256 ethIn = 1 ether;
        vm.deal(user, ethIn);

        vm.prank(user);
        minter.deposit{ value: ethIn }();

        uint256 minted = minter.totalMinted();
        uint256 feeOnMint = seth.feeAccrued();

        vm.prank(user);
        minter.withdraw(minted);

        assertEq(seth.balanceOf(user), 0);
        assertEq(minter.totalMinted(), minted); // cumulative unchanged
        assertEq(registry.totalMinted(appId), minted);
        assertEq(registry.netMinted(appId), 0); // outstanding cleared
        assertGt(seth.feeAccrued(), feeOnMint);
        assertEq(user.balance, ethIn - seth.feeAccrued());
    }

    function test_pullFees_intoTreasury() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        seth.deposit{ value: 1 ether }();

        uint256 fees = seth.feeAccrued();
        uint256 redeemable = seth.redeemableCollateral();

        treasury.pullAllFees();

        assertEq(seth.feeAccrued(), 0);
        assertEq(treasury.rewardsR(), fees);
        assertEq(address(seth).balance, redeemable);
        assertTrue(seth.isFullyBacked());
    }

    function test_register_onlyOwner() public {
        address other = makeAddr("other");
        address[] memory tvl = new address[](1);
        tvl[0] = address(new MockTvlContract(other));

        vm.prank(other);
        vm.expectRevert();
        registry.register(other, tvl);
    }

    function test_addTvlContracts_onlyOwner() public {
        address[] memory tvl = new address[](1);
        tvl[0] = address(new MockTvlContract(rootDeployer));

        vm.prank(rootDeployer);
        vm.expectRevert();
        registry.addTvlContracts(appId, tvl);
    }

    function test_rootDeployer_setsBeneficiaries() public {
        AppRegistry.Beneficiary[] memory next = new AppRegistry.Beneficiary[](2);
        next[0] = AppRegistry.Beneficiary({ account: rootDeployer, shareBps: 7_000 });
        next[1] = AppRegistry.Beneficiary({ account: beneficiary, shareBps: 3_000 });

        vm.prank(rootDeployer);
        registry.setBeneficiaries(appId, next);

        assertTrue(registry.isBeneficiary(appId, rootDeployer));
        assertTrue(registry.isBeneficiary(appId, beneficiary));
        assertEq(registry.beneficiaryShareBps(appId, beneficiary), 3_000);
    }

    function test_claim_onlyBeneficiary() public {
        vm.prank(user);
        vm.expectRevert(Minter.NotBeneficiary.selector);
        minter.claim(1);
    }

    function test_creSettle_andClaim() public {
        // Accrue fees via wrap
        vm.deal(user, 10 ether);
        vm.prank(user);
        minter.deposit{ value: 10 ether }();
        treasury.pullAllFees();

        uint256 R = treasury.rewardsR();
        assertGt(R, 0);

        // Single app: m=1, s=1 → I_app = R, rootDeployer share 100%
        bytes32[] memory appIds = new bytes32[](1);
        appIds[0] = appId;
        uint256[] memory mScores = new uint256[](1);
        mScores[0] = 1;
        uint256[] memory sScores = new uint256[](1);
        sScores[0] = 1;

        PBRTreasury.CreReport memory report =
            PBRTreasury.CreReport({ epochId: 1, appIds: appIds, mScores: mScores, sScores: sScores });

        vm.prank(forwarder);
        treasury.onReport(_creMetadata(WORKFLOW_ID), abi.encode(report));

        assertEq(treasury.lastEpochId(), 1);
        assertEq(treasury.rewardsR(), 0);

        uint256 balBefore = rootDeployer.balance;
        vm.prank(rootDeployer);
        uint256 payout = minter.claim(1);

        assertEq(payout, R);
        assertEq(rootDeployer.balance, balBefore + R);
        assertTrue(treasury.isClaimed(appId, rootDeployer, 1));

        vm.prank(rootDeployer);
        vm.expectRevert(PBRTreasury.AlreadyClaimed.selector);
        minter.claim(1);
    }

    function test_settle_skipsUnusedMinterEvenWithTvlScores() public {
        // Second app: registered TVL, never minted through its minter
        address otherDeployer = makeAddr("otherDeployer");
        address[] memory tvl2 = new address[](1);
        tvl2[0] = address(new MockTvlContract(otherDeployer));
        vm.prank(owner);
        (bytes32 appId2,) = registry.register(otherDeployer, tvl2);

        vm.deal(user, 10 ether);
        vm.prank(user);
        minter.deposit{ value: 10 ether }();
        treasury.pullAllFees();

        bytes32[] memory appIds = new bytes32[](2);
        appIds[0] = appId;
        appIds[1] = appId2;
        uint256[] memory mScores = new uint256[](2);
        mScores[0] = 1;
        mScores[1] = 100; // would dominate if accepted
        uint256[] memory sScores = new uint256[](2);
        sScores[0] = 1;
        sScores[1] = 100;

        assertEq(registry.netMinted(appId2), 0);

        vm.prank(forwarder);
        treasury.onReport(
            _creMetadata(WORKFLOW_ID),
            abi.encode(
                PBRTreasury.CreReport({ epochId: 1, appIds: appIds, mScores: mScores, sScores: sScores })
            )
        );

        // Only appId1 accepted → full R to that app's sole beneficiary
        assertEq(treasury.epochM(1, appId2), 0);
        assertEq(treasury.epochM(1, appId), 1);

        uint256 R = treasury.getEpoch(1).R;
        vm.prank(rootDeployer);
        assertEq(minter.claim(1), R);
    }

    function test_claim_respectsBeneficiaryShares() public {
        AppRegistry.Beneficiary[] memory next = new AppRegistry.Beneficiary[](2);
        next[0] = AppRegistry.Beneficiary({ account: rootDeployer, shareBps: 7_000 });
        next[1] = AppRegistry.Beneficiary({ account: beneficiary, shareBps: 3_000 });
        vm.prank(rootDeployer);
        registry.setBeneficiaries(appId, next);

        vm.deal(user, 10 ether);
        vm.prank(user);
        minter.deposit{ value: 10 ether }(); // must use minter so netMinted > 0
        treasury.pullAllFees();
        uint256 R = treasury.rewardsR();

        bytes32[] memory appIds = new bytes32[](1);
        appIds[0] = appId;
        uint256[] memory mScores = new uint256[](1);
        mScores[0] = 1 ether;
        uint256[] memory sScores = new uint256[](1);
        sScores[0] = 1 ether;

        vm.prank(forwarder);
        treasury.onReport(
            _creMetadata(WORKFLOW_ID),
            abi.encode(
                PBRTreasury.CreReport({ epochId: 1, appIds: appIds, mScores: mScores, sScores: sScores })
            )
        );

        vm.prank(beneficiary);
        uint256 payout = minter.claim(1);
        assertEq(payout, (R * 3_000) / 10_000);
    }

    function _creMetadata(
        bytes32 workflowId
    ) internal pure returns (bytes memory metadata) {
        // 62-byte layout: workflowId | workflowName(10) | workflowOwner(20)
        metadata = abi.encodePacked(workflowId, bytes10(0), address(0));
        require(metadata.length == 62, "bad metadata");
    }
}
