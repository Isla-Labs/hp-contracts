// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol";

import { CvmClient } from "@src/oracle/CvmClient.sol";
import { CvmCoordinator } from "@src/oracle/CvmCoordinator.sol";
import { CvmRouter } from "@src/oracle/CvmRouter.sol";
import { MockAttestationVerifier } from "@src/oracle/attestation/MockAttestationVerifier.sol";
import { CvmErrors as Errors } from "@errors/oracle/CvmErrors.sol";
import { AttestationClaim, CvmCommitment, CvmJob, CvmRouterConfig } from "@types/oracle/CvmTypes.sol";

contract MockCvmConsumer is CvmClient {
    bytes32 public lastRequestId;
    bytes public lastResponse;
    bytes public lastErr;

    constructor(address router_) CvmClient(router_) { }

    function request(bytes calldata args) external returns (bytes32) {
        return _sendRequest(CvmJob.TestFetch, args);
    }

    function requestJob(CvmJob job, bytes calldata args) external returns (bytes32) {
        return _sendRequest(job, args);
    }

    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        lastRequestId = requestId;
        lastResponse = response;
        lastErr = err;
    }
}

contract CvmRouterTest is Test {
    address internal dao = makeAddr("dao");
    address internal oracleA = makeAddr("oracleA");
    address internal oracleB = makeAddr("oracleB");

    bytes32 internal constant DEVICE_A = keccak256("device-a");
    bytes32 internal constant DEVICE_B = keccak256("device-b");
    bytes32 internal constant COMPOSE_A = keccak256("compose-a");
    bytes32 internal constant COMPOSE_B = keccak256("compose-b");

    CvmCoordinator internal coordinator;
    CvmRouter internal router;
    MockCvmConsumer internal consumer;

    uint32 internal constant EXCLUSIVE_FAST = 60;
    uint32 internal constant EXCLUSIVE_SETTLE = 15 minutes;
    uint32 internal constant TIMEOUT = 1 hours;

    function setUp() public {
        MockAttestationVerifier verifier = new MockAttestationVerifier(1 hours);

        CvmCoordinator coordImpl = new CvmCoordinator();
        coordinator = CvmCoordinator(
            address(
                new TransparentUpgradeableProxy(
                    address(coordImpl), dao, abi.encodeCall(CvmCoordinator.initialize, (dao, address(verifier), 1 days))
                )
            )
        );

        CvmRouterConfig memory cfg =
            CvmRouterConfig({ maxCallbackGasLimit: 500_000, requestTimeout: TIMEOUT, gasForCallExactCheck: 5000 });
        CvmRouter routerImpl = new CvmRouter();
        router = CvmRouter(
            address(
                new TransparentUpgradeableProxy(
                    address(routerImpl), dao, abi.encodeCall(CvmRouter.initialize, (dao, address(coordinator), cfg))
                )
            )
        );
        consumer = new MockCvmConsumer(address(router));

        vm.startPrank(dao);
        coordinator.addComposeHash(COMPOSE_A);
        coordinator.addComposeHash(COMPOSE_B);
        vm.stopPrank();

        coordinator.registerOracle(abi.encode(_claim(oracleA, DEVICE_A, COMPOSE_A, keccak256("n-a"))));
        coordinator.registerOracle(abi.encode(_claim(oracleB, DEVICE_B, COMPOSE_B, keccak256("n-b"))));
    }

    function _claim(
        address transmitter,
        bytes32 deviceId,
        bytes32 composeHash,
        bytes32 nonce
    ) internal view returns (AttestationClaim memory) {
        return AttestationClaim({
            transmitter: transmitter,
            deviceId: deviceId,
            composeHash: composeHash,
            nonce: nonce,
            quotedAt: uint64(block.timestamp)
        });
    }

    function test_sendRequest_assignsLiveOracle() public {
        bytes32 id = consumer.request("hello");
        CvmCommitment memory c = router.getCommitment(id);
        assertTrue(c.assignee == oracleA || c.assignee == oracleB);
        assertEq(c.exclusiveUntil, uint64(block.timestamp) + EXCLUSIVE_FAST);
        assertEq(c.timeoutAt, uint64(block.timestamp) + TIMEOUT);
        assertEq(router.jobExclusiveSeconds(CvmJob.TestFetch), EXCLUSIVE_FAST);
    }

    function test_sendRequest_settleDmsUsesLongerExclusive() public {
        bytes32 id = consumer.requestJob(CvmJob.SettleDms, "settle");
        CvmCommitment memory c = router.getCommitment(id);
        assertEq(c.exclusiveUntil, uint64(block.timestamp) + EXCLUSIVE_SETTLE);
        assertEq(router.jobExclusiveSeconds(CvmJob.SettleDms), EXCLUSIVE_SETTLE);
    }

    function test_setJobExclusiveSeconds() public {
        vm.prank(dao);
        router.setJobExclusiveSeconds(CvmJob.TestFetch, 90);

        bytes32 id = consumer.request("hello");
        assertEq(router.getCommitment(id).exclusiveUntil, uint64(block.timestamp) + 90);
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

        vm.warp(block.timestamp + EXCLUSIVE_FAST + 1);

        vm.prank(other);
        router.fulfill(id, abi.encode("failover"), "");
        assertEq(consumer.lastRequestId(), id);
    }

    function test_sendRequest_revertsWithoutLiveOracle() public {
        vm.startPrank(dao);
        coordinator.removeComposeHash(COMPOSE_A);
        coordinator.removeComposeHash(COMPOSE_B);
        vm.stopPrank();

        vm.expectRevert(Errors.NoLiveOracle.selector);
        consumer.request("hello");
    }

    function test_pickAssignee_skipsInactiveCompose() public {
        vm.prank(dao);
        coordinator.removeComposeHash(COMPOSE_A);

        address picked = coordinator.pickAssignee(bytes32(uint256(0)));
        assertEq(picked, oracleB);
        assertEq(coordinator.pickAssignee(keccak256("x")), oracleB);
    }
}
