// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import { AppRegistry } from "@stabilityeth/AppRegistry.sol";
import { Minter } from "@stabilityeth/Minter.sol";
import { MinterFactory } from "@stabilityeth/base/factories/MinterFactory.sol";
import { PBRScoreOracle } from "@stabilityeth/pbr/PBRScoreOracle.sol";
import { PBRTreasury } from "@stabilityeth/pbr/PBRTreasury.sol";
import { SETH } from "@stabilityeth/SETH.sol";
import { MockTvlContract } from "./MockTvlContract.sol";

contract SETHTest is Test {
    address internal owner = makeAddr("owner");
    address internal rootDeployer = makeAddr("rootDeployer");
    address internal user = makeAddr("user");
    address internal beneficiary = makeAddr("beneficiary");
    address internal scoreForwarder = makeAddr("scoreForwarder");
    address internal distForwarder = makeAddr("distForwarder");

    bytes32 internal constant SCORE_WORKFLOW = keccak256("seth-scores-v1");
    bytes32 internal constant DIST_WORKFLOW = keccak256("seth-distribute-v1");
    uint16 internal constant DECAY_BPS = 9_000;

    SETH internal seth;
    MinterFactory internal factory;
    AppRegistry internal registry;
    PBRScoreOracle internal oracle;
    PBRTreasury internal treasury;
    Minter internal minter;
    bytes32 internal appId;

    function setUp() public {
        // Predict treasury proxy CREATE address so SETH.feeCollector can be immutable.
        // Order below: treImpl, seth, factory, registry, scoreImpl, oracleProxy, treasuryProxy.
        uint64 n = uint64(vm.getNonce(address(this)));
        address predictedTreasury = vm.computeCreateAddress(address(this), n + 6);

        PBRTreasury treImpl = new PBRTreasury();
        seth = new SETH(predictedTreasury);
        factory = new MinterFactory(address(seth), owner, owner);
        registry = new AppRegistry(address(seth), address(factory), owner);

        PBRScoreOracle scoreImpl = new PBRScoreOracle();
        oracle = PBRScoreOracle(
            address(
                new ERC1967Proxy(
                    address(scoreImpl),
                    abi.encodeCall(
                        PBRScoreOracle.initialize,
                        (owner, address(registry), scoreForwarder, SCORE_WORKFLOW, DECAY_BPS)
                    )
                )
            )
        );

        treasury = PBRTreasury(
            payable(
                address(
                    new ERC1967Proxy(
                        address(treImpl),
                        abi.encodeCall(
                            PBRTreasury.initialize,
                            (
                                owner,
                                address(seth),
                                address(registry),
                                address(oracle),
                                distForwarder,
                                DIST_WORKFLOW
                            )
                        )
                    )
                )
            )
        );
        require(address(treasury) == predictedTreasury, "treasury address mismatch");
        assertEq(seth.feeCollector(), address(treasury));

        vm.startPrank(owner);
        factory.setRegistry(address(registry));
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

        uint256 fee = ethIn / 1000;
        assertEq(seth.balanceOf(user), (ethIn - fee) * 100);
        assertEq(seth.feeAccrued(), fee);
        assertTrue(seth.isFullyBacked());
    }

    function test_minterDeposit_creditsAppTotalMinted() public {
        uint256 ethIn = 1 ether;
        vm.deal(user, ethIn);

        vm.prank(user);
        minter.deposit{ value: ethIn }();

        uint256 expectedSeth = (ethIn - ethIn / 1000) * 100;
        assertEq(seth.balanceOf(user), expectedSeth);
        assertEq(registry.totalMinted(appId), expectedSeth);
        assertEq(registry.netMinted(appId), expectedSeth);
    }

    function test_minterWithdraw_clearsNetMinted() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.deposit{ value: 1 ether }();

        uint256 minted = minter.totalMinted();
        vm.startPrank(user);
        seth.approve(address(minter), minted);
        minter.withdraw(minted);
        vm.stopPrank();

        assertEq(registry.totalMinted(appId), minted);
        assertEq(registry.netMinted(appId), 0);
        assertEq(seth.balanceOf(user), 0);
    }

    function test_scoreOracle_appliesOnchainDecay() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.deposit{ value: 1 ether }();
        uint256 minted = registry.totalMinted(appId);

        _pushScores(appId, 100 ether, minted);
        assertEq(oracle.runningM(appId), (100 ether * 1000) / 10_000);
        assertEq(oracle.runningS(appId), minted);

        uint256 m1 = oracle.runningM(appId);
        uint256 s1 = oracle.runningS(appId);
        _pushScores(appId, 100 ether, minted);

        uint256 expectedM = (m1 * uint256(DECAY_BPS) + 100 ether * uint256(10_000 - DECAY_BPS)) / 10_000;
        uint256 expectedS = (s1 * uint256(DECAY_BPS)) / 10_000;
        assertEq(oracle.runningM(appId), expectedM);
        assertEq(oracle.runningS(appId), expectedS);
    }

    function test_dailyDistribute_snapshotsOracleAndClaimAll() public {
        vm.deal(user, 10 ether);
        vm.prank(user);
        minter.deposit{ value: 10 ether }();
        uint256 minted = registry.totalMinted(appId);

        _pushScores(appId, 50 ether, minted);

        bytes32[] memory appIds = new bytes32[](1);
        appIds[0] = appId;

        vm.prank(distForwarder);
        treasury.onReport(
            _creMetadata(DIST_WORKFLOW),
            abi.encode(PBRTreasury.DistributeReport({ epochId: 1, appIds: appIds }))
        );

        assertEq(treasury.lastEpochId(), 1);
        assertEq(treasury.epochM(1, appId), oracle.runningM(appId));
        assertEq(treasury.epochS(1, appId), oracle.runningS(appId));

        uint256 R = treasury.getEpoch(1).R;
        assertGt(R, 0);

        uint256 balBefore = rootDeployer.balance;
        vm.prank(rootDeployer);
        (uint256 totalPayout, uint64 next) = minter.claimAll(1);

        assertEq(totalPayout, R);
        assertEq(next, 2);
        assertEq(rootDeployer.balance, balBefore + R);
        assertTrue(treasury.isClaimed(appId, rootDeployer, 1));
    }

    function test_distribute_skipsUnusedMinter() public {
        address otherDeployer = makeAddr("otherDeployer");
        address[] memory tvl2 = new address[](1);
        tvl2[0] = address(new MockTvlContract(otherDeployer));
        vm.prank(owner);
        (bytes32 appId2,) = registry.register(otherDeployer, tvl2);

        vm.deal(user, 5 ether);
        vm.prank(user);
        minter.deposit{ value: 5 ether }();
        _pushScores(appId, 10 ether, registry.totalMinted(appId));
        _pushScores(appId2, 1_000 ether, 0);
        assertEq(oracle.runningM(appId2), 0);
        assertEq(oracle.runningS(appId2), 0);

        bytes32[] memory appIds = new bytes32[](2);
        appIds[0] = appId;
        appIds[1] = appId2;

        vm.prank(distForwarder);
        treasury.onReport(
            _creMetadata(DIST_WORKFLOW),
            abi.encode(PBRTreasury.DistributeReport({ epochId: 1, appIds: appIds }))
        );

        assertEq(treasury.epochM(1, appId2), 0);
        assertGt(treasury.epochM(1, appId), 0);
    }

    function test_scoreWorkflow_cannotCallTreasury() public {
        bytes32[] memory appIds = new bytes32[](1);
        appIds[0] = appId;

        vm.prank(scoreForwarder);
        vm.expectRevert();
        treasury.onReport(
            _creMetadata(DIST_WORKFLOW),
            abi.encode(PBRTreasury.DistributeReport({ epochId: 1, appIds: appIds }))
        );
    }

    function test_claim_respectsBeneficiaryShares() public {
        AppRegistry.Beneficiary[] memory next = new AppRegistry.Beneficiary[](2);
        next[0] = AppRegistry.Beneficiary({ account: rootDeployer, shareBps: 7_000 });
        next[1] = AppRegistry.Beneficiary({ account: beneficiary, shareBps: 3_000 });
        vm.prank(rootDeployer);
        registry.setBeneficiaries(appId, next);

        vm.deal(user, 10 ether);
        vm.prank(user);
        minter.deposit{ value: 10 ether }();
        _pushScores(appId, 1 ether, registry.totalMinted(appId));

        bytes32[] memory appIds = new bytes32[](1);
        appIds[0] = appId;

        vm.prank(distForwarder);
        treasury.onReport(
            _creMetadata(DIST_WORKFLOW),
            abi.encode(PBRTreasury.DistributeReport({ epochId: 1, appIds: appIds }))
        );

        uint256 R = treasury.getEpoch(1).R;
        vm.prank(beneficiary);
        assertEq(minter.claim(1), (R * 3_000) / 10_000);
    }

    function _pushScores(bytes32 id, uint256 tvlRaw, uint256 totalMintedObserved) internal {
        bytes32[] memory appIds = new bytes32[](1);
        appIds[0] = id;
        uint256[] memory tvl = new uint256[](1);
        tvl[0] = tvlRaw;
        uint256[] memory minted = new uint256[](1);
        minted[0] = totalMintedObserved;

        vm.prank(scoreForwarder);
        oracle.onReport(
            _creMetadata(SCORE_WORKFLOW),
            abi.encode(
                PBRScoreOracle.ObservationReport({
                    appIds: appIds, tvlRaw: tvl, totalMintedObserved: minted
                })
            )
        );
    }

    function _creMetadata(
        bytes32 workflowId
    ) internal pure returns (bytes memory metadata) {
        metadata = abi.encodePacked(workflowId, bytes10(0), address(0));
        require(metadata.length == 62, "bad metadata");
    }
}
