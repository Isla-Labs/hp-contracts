// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CvmErrors as Errors } from "@errors/oracle/CvmErrors.sol";
import { ICvmClient } from "@interfaces/oracle/ICvmClient.sol";
import { ICvmRouter } from "@interfaces/oracle/ICvmRouter.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";

/**
 * @title CvmClient
 * @notice Inherit to open Phala CVM oracle requests via `CvmRouter`.
 * @dev Mirrors Chainlink FunctionsClient: `_sendRequest` → router → `handleOracleFulfillment`
 *      → child `_fulfillRequest`. The router allowlists callers via `setRequester`; put
 *      `RateLimit` on the consumer's public kickoff, not here.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
abstract contract CvmClient is ICvmClient {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    ICvmRouter internal immutable i_router;

    // --------------------------------------------
    //  Events
    // --------------------------------------------

    event RequestSent(bytes32 indexed requestId);
    event RequestFulfilled(bytes32 indexed requestId);

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    constructor(address router_) {
        if (router_ == address(0)) revert Errors.ZeroAddress();
        i_router = ICvmRouter(router_);
    }

    // --------------------------------------------
    //  Request helpers
    // --------------------------------------------

    /**
     * @notice Open a CVM job through the router.
     * @param job Allowlisted script the CVM must run.
     * @param args ABI-encoded public args for that job (no secrets).
     * @return requestId Correlator for the pending request.
     * @dev Callback gas is router-global `maxCallbackGasLimit`.
     */
    function _sendRequest(CvmJob job, bytes memory args) internal returns (bytes32 requestId) {
        requestId = i_router.sendRequest(job, args);
        emit RequestSent(requestId);
    }

    /**
     * @notice Domain logic for a successful / errored oracle reply.
     * @dev Either `response` or `err` is typically set by the CVM; handle both.
     */
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal virtual;

    /// @inheritdoc ICvmClient
    function handleOracleFulfillment(bytes32 requestId, bytes memory response, bytes memory err) external override {
        if (msg.sender != address(i_router)) revert Errors.OnlyRouter(msg.sender);
        _fulfillRequest(requestId, response, err);
        emit RequestFulfilled(requestId);
    }
}
