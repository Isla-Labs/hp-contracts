// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { ICvmClient } from "@interfaces/oracle/ICvmClient.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";

/// @notice Minimal CVM router for PbrHistorical / PbrSettle unit tests.
contract MockCvmRouter {
    uint256 public requestCount;

    struct Pending {
        address consumer;
        CvmJob job;
        bytes args;
    }

    mapping(bytes32 requestId => Pending) public pending;
    bytes32 public lastRequestId;

    /// @dev Chronological request ids for draining multi-fixture fan-outs.
    bytes32[] public requestIds;

    function sendRequest(CvmJob job, bytes calldata args) external returns (bytes32 requestId) {
        unchecked {
            ++requestCount;
        }
        requestId = keccak256(abi.encode(msg.sender, job, args, requestCount, block.timestamp));
        pending[requestId] = Pending({ consumer: msg.sender, job: job, args: args });
        lastRequestId = requestId;
        requestIds.push(requestId);
    }

    function fulfill(bytes32 requestId, bytes calldata response, bytes calldata err) external {
        Pending memory p = pending[requestId];
        require(p.consumer != address(0), "unknown request");
        delete pending[requestId];
        ICvmClient(p.consumer).handleOracleFulfillment(requestId, response, err);
    }

    function getPending(bytes32 requestId) external view returns (address consumer, CvmJob job, bytes memory args) {
        Pending memory p = pending[requestId];
        return (p.consumer, p.job, p.args);
    }

    function requestIdAt(uint256 index) external view returns (bytes32) {
        return requestIds[index];
    }

    function clearRequestLog() external {
        delete requestIds;
    }
}
