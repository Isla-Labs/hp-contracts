// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { DelayedBatchExecutor } from "@governance/core/DelayedBatchExecutor.sol";
import { GovernanceTypes } from "@governance/core/GovernanceTypes.sol";
import { IProofVerifier } from "@governance/core/IProofVerifier.sol";
import { LifecycleExecutor } from "@governance/executors/LifecycleExecutor.sol";
import { ConstitutionalTimelock } from "@governance/constitutional/ConstitutionalTimelock.sol";

contract MockTarget {
    uint256 public value;

    function setValue(uint256 v) external {
        value = v;
    }
}

contract AcceptAllVerifier is IProofVerifier {
    function verify(bytes calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

contract RejectAllVerifier is IProofVerifier {
    function verify(bytes calldata, bytes calldata) external pure returns (bool) {
        return false;
    }
}

contract DelayedBatchExecutorTest is Test {
    LifecycleExecutor internal executor;
    MockTarget internal target;
    address internal admin = makeAddr("admin");
    address internal proposer = makeAddr("proposer");

    function setUp() public {
        executor = new LifecycleExecutor(admin);
        target = new MockTarget();

        vm.startPrank(admin);
        executor.grantRole(executor.PROPOSER_ROLE(), proposer);
        vm.stopPrank();
    }

    function test_scheduleAndExecuteAfterDelay() public {
        GovernanceTypes.Action[] memory actions = new GovernanceTypes.Action[](1);
        actions[0] = GovernanceTypes.Action({
            to: address(target), value: 0, data: abi.encodeCall(MockTarget.setValue, (42))
        });

        bytes32 salt = bytes32(uint256(1));
        uint256 delay = executor.minDelay();

        vm.prank(proposer);
        bytes32 opId = executor.schedule(actions, salt, delay);

        assertEq(executor.getReadyAt(opId), block.timestamp + delay);

        vm.expectRevert();
        executor.execute(actions, salt);

        vm.warp(block.timestamp + delay);
        executor.execute(actions, salt);

        assertEq(target.value(), 42);
        assertTrue(executor.isOperationDone(opId));
    }

    function test_executeWithProof() public {
        AcceptAllVerifier verifier = new AcceptAllVerifier();
        vm.prank(admin);
        executor.setProofVerifier(address(verifier));

        GovernanceTypes.Action[] memory actions = new GovernanceTypes.Action[](1);
        actions[0] = GovernanceTypes.Action({
            to: address(target), value: 0, data: abi.encodeCall(MockTarget.setValue, (7))
        });

        executor.executeWithProof(actions, bytes32(uint256(2)), hex"00", hex"00");
        assertEq(target.value(), 7);
    }

    function test_executeWithProof_rejectsBadProof() public {
        RejectAllVerifier verifier = new RejectAllVerifier();
        vm.prank(admin);
        executor.setProofVerifier(address(verifier));

        GovernanceTypes.Action[] memory actions = new GovernanceTypes.Action[](1);
        actions[0] = GovernanceTypes.Action({
            to: address(target), value: 0, data: abi.encodeCall(MockTarget.setValue, (1))
        });

        vm.expectRevert(DelayedBatchExecutor.ProofRejected.selector);
        executor.executeWithProof(actions, bytes32(0), hex"00", hex"00");
    }

    function test_cancel() public {
        GovernanceTypes.Action[] memory actions = new GovernanceTypes.Action[](1);
        actions[0] = GovernanceTypes.Action({
            to: address(target), value: 0, data: abi.encodeCall(MockTarget.setValue, (9))
        });

        uint256 delay = executor.minDelay();
        vm.prank(proposer);
        bytes32 opId = executor.schedule(actions, bytes32(uint256(3)), delay);

        vm.prank(admin);
        executor.cancel(opId);

        vm.warp(block.timestamp + delay);
        vm.expectRevert(abi.encodeWithSelector(DelayedBatchExecutor.UnknownOperation.selector, opId));
        executor.execute(actions, bytes32(uint256(3)));
    }

    function test_constitutionalTimelock_deploys() public {
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        ConstitutionalTimelock tl = new ConstitutionalTimelock(7 days, proposers, executors, admin);
        assertEq(tl.getMinDelay(), 7 days);
        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), admin));
    }
}
