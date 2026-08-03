// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CvmClient } from "@src/oracle/CvmClient.sol";
import { CvmErrors as Errors } from "@errors/oracle/CvmErrors.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";

/**
 * @title Oracle
 * @notice Abstract CVM oracle client for data-plane / ops contracts.
 * @dev Thin helper over `CvmClient`: `_sendOracleRequest(job, args)`. Callback gas is the
 *      router-global `maxCallbackGasLimit` (DAO-configured) — not per-consumer.
 *
 *      Multi-job children demux fulfills via their own `requestId → kind` maps.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
abstract contract Oracle is CvmClient {
    /// @notice Last request id returned by the router (monitoring / correlation).
    bytes32 public lastRequestId;

    /// @param router_ `CvmRouter` for this chain.
    constructor(address router_) CvmClient(router_) { }

    /// @notice Open a CVM request for `job_`. Gas stipend = router `maxCallbackGasLimit`.
    function _sendOracleRequest(CvmJob job_, bytes memory args) internal returns (bytes32 requestId) {
        if (job_ == CvmJob.None) revert Errors.InvalidJob(job_);
        requestId = _sendRequest(job_, args);
        lastRequestId = requestId;
    }

    /// @inheritdoc CvmClient
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal virtual override;
}
