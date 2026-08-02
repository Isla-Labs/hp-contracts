// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol";

import { CvmClient } from "@src/oracle/CvmClient.sol";
import { CvmCoordinator } from "@src/oracle/CvmCoordinator.sol";
import { CvmRouter } from "@src/oracle/CvmRouter.sol";
import { CvmErrors as Errors } from "@errors/oracle/CvmErrors.sol";
import { CvmCommitment, CvmJob, CvmRouterConfig } from "@types/oracle/CvmTypes.sol";

contract MockCvmConsumer is CvmClient {
    bytes32 public lastRequestId;
    bytes public lastResponse;
    bytes public lastErr;

    constructor(address router_) CvmClient(router_) { }

    function request(bytes calldata args) external returns (bytes32) {
        return _sendRequest(CvmJob.TestFetch, args, 300_000);
    }

    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        lastRequestId = requestId;
        lastResponse = response;
        lastErr = err;
    }
}

contract CvmRouterTest is Test {
    address internal dao = makeAddr("dao");
    address internal constitutional = makeAddr("constitutional");
    address internal oracleA = makeAddr("oracleA");
    address internal oracleB = makeAddr("oracleB");

    bytes32 internal constant DEVICE_A = keccak256("device-a");
    bytes32 internal constant DEVICE_B = keccak256("device-b");

    CvmCoordinator internal coordinator;
    CvmRouter internal router;
    MockCvmConsumer internal consumer;

    uint32 internal constant EXCLUSIVE = 5 minutes;
    uint32 internal constant TIMEOUT = 1 hours;

    function setUp() public {
        CvmCoordinator coordImpl = new CvmCoordinator();
        coordinator = CvmCoordinator(
            address(
                new TransparentUpgradeableProxy(
                    address(coordImpl),
                    dao,
                    abi.encodeCall(CvmCoordinator.initialize, (dao, constitutional, address(0), 1 days))
                )
            )
        );

        CvmRouterConfig memory cfg = CvmRouterConfig({
            maxCallbackGasLimit: 500_000,
            requestTimeout: TIMEOUT,
            gasForCallExactCheck: 5000,
            assigneeExclusiveSeconds: EXCLUSIVE
        });
        CvmRouter routerImpl = new CvmRouter();
        router = CvmRouter(
            address(
                new TransparentUpgradeableProxy(
                    address(routerImpl),
                    dao,
                    abi.encodeCall(CvmRouter.initialize, (dao, constitutional, address(coordinator), cfg))
                )
            )
        );
        consumer = new MockCvmConsumer(address(router));

        vm.startPrank(constitutional);
        coordinator.registerOracleBreakglass(DEVICE_A, oracleA);
        coordinator.registerOracleBreakglass(DEVICE_B, oracleB);
        vm.stopPrank();
    }

    function test_sendRequest_assignsLiveOracle() public {
        bytes32 id = consumer.request("hello");
        CvmCommitment memory c = router.getCommitment(id);
        assertTrue(c.assignee == oracleA || c.assignee == oracleB);
        assertEq(c.exclusiveUntil, uint64(block.timestamp) + EXCLUSIVE);
        assertEq(c.timeoutAt, uint64(block.timestamp) + TIMEOUT);
    }

    function test_fulfill_onlyAssigneeDuringExclusiveWindow() public {
        bytes32 id = consumer.request("hello");
        address assignee = router.getCommitment(id).assignee;
        address other = assignee == oracleA ? oracleB : oracleA;

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyAssignee.selector, assignee, other));
        router.fulfill(id, abi.encode("ok"), "");

        vm.prank(assignee);
        router.fulfill(id, abi.encode("ok"), "");
        assertEq(consumer.lastRequestId(), id);
        assertFalse(router.isPending(id));
    }

    function test_fulfill_failoverAfterExclusiveWindow() public {
        bytes32 id = consumer.request("hello");
        address assignee = router.getCommitment(id).assignee;
        address other = assignee == oracleA ? oracleB : oracleA;

        vm.warp(block.timestamp + EXCLUSIVE + 1);

        vm.prank(other);
        router.fulfill(id, abi.encode("failover"), "");
        assertEq(consumer.lastRequestId(), id);
    }

    function test_sendRequest_revertsWithoutLiveOracle() public {
        vm.startPrank(constitutional);
        coordinator.revokeOracle(oracleA);
        coordinator.revokeOracle(oracleB);
        vm.stopPrank();

        vm.expectRevert(Errors.NoLiveOracle.selector);
        consumer.request("hello");
    }

    function test_pickAssignee_skipsRevoked() public {
        vm.prank(constitutional);
        coordinator.revokeOracle(oracleA);

        address picked = coordinator.pickAssignee(bytes32(uint256(0)));
        assertEq(picked, oracleB);
        assertEq(coordinator.pickAssignee(keccak256("x")), oracleB);
    }
}
