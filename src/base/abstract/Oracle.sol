// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CvmClient } from "@src/oracle/CvmClient.sol";
import { CvmErrors as Errors } from "@errors/oracle/CvmErrors.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";

/**
 * @title Oracle
 * @notice Abstract CVM oracle client for data-plane contracts (`EligibilityStore`, …).
 * @dev Extends `CvmClient` the way the legacy Functions `Oracle` extended `FunctionsClient`:
 *      preconfigure `job` + `fulfillGasLimit`, then `_sendOracleRequest(args)` → `CvmRouter`
 *      → `handleOracleFulfillment` → child `_fulfillRequest`.
 *
 *      Usage:
 *        `contract EligibilityStore is …, Oracle { … }`
 *        constructor wires `CvmRouter`, the fixed `CvmJob`, and callback gas.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
abstract contract Oracle is CvmClient {
    // --------------------------------------------
    //  Configuration
    // --------------------------------------------

    /// @notice Last request id returned by the router (monitoring / correlation).
    bytes32 public lastRequestId;

    /// @notice Preconfigured CVM script this consumer always requests.
    CvmJob public job;

    /// @notice Gas reserved for `handleOracleFulfillment` → `_fulfillRequest`.
    uint32 public fulfillGasLimit;

    // --------------------------------------------
    //  Errors
    // --------------------------------------------

    error OracleNotConfigured();

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /**
     * @param router_ `CvmRouter` for this chain (not an `AddressProvider` key).
     * @param job_ Fixed allowlisted `CvmJob` for this consumer (`None` rejected).
     * @param fulfillGasLimit_ Callback gas limit forwarded on each request.
     */
    constructor(address router_, CvmJob job_, uint32 fulfillGasLimit_) CvmClient(router_) {
        if (job_ == CvmJob.None) revert Errors.InvalidJob(job_);
        if (fulfillGasLimit_ == 0) revert OracleNotConfigured();
        job = job_;
        fulfillGasLimit = fulfillGasLimit_;
    }

    // --------------------------------------------
    //  Admin (optional: child can expose via roles)
    // --------------------------------------------

    function _setJob(CvmJob job_) internal {
        if (job_ == CvmJob.None) revert Errors.InvalidJob(job_);
        job = job_;
    }

    function _setFulfillGasLimit(uint32 fulfillGasLimit_) internal {
        if (fulfillGasLimit_ == 0) revert OracleNotConfigured();
        fulfillGasLimit = fulfillGasLimit_;
    }

    // --------------------------------------------
    //  Request helpers
    // --------------------------------------------

    /// @notice Open a request with the preconfigured `job` and `fulfillGasLimit`.
    function _sendOracleRequest(bytes memory args) internal returns (bytes32 requestId) {
        _requireOracleConfig();
        return _storeLast(_sendRequest(job, args, fulfillGasLimit));
    }

    /// @notice Open a request with the preconfigured `job` and an explicit callback gas limit.
    function _sendOracleRequest(bytes memory args, uint32 callbackGasLimit) internal returns (bytes32 requestId) {
        _requireOracleConfig();
        if (callbackGasLimit == 0) revert OracleNotConfigured();
        return _storeLast(_sendRequest(job, args, callbackGasLimit));
    }

    // --------------------------------------------
    //  Internal
    // --------------------------------------------

    function _requireOracleConfig() internal view {
        if (job == CvmJob.None || fulfillGasLimit == 0) revert OracleNotConfigured();
    }

    function _storeLast(bytes32 requestId) private returns (bytes32) {
        lastRequestId = requestId;
        return requestId;
    }

    /// @inheritdoc CvmClient
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal virtual override;
}
