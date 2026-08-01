// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Oracle } from "@base/abstract/Oracle.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";

/**
 * @title TestData
 * @notice Minimal Sepolia consumer for CVM `TestFetch` end-to-end smokes.
 * @dev Flow: `request(query)` → `CvmRouter` → attested worker → `_fulfillRequest`.
 *      Args / response ABI (v1): `abi.encode(string)` both ways.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TestData is Oracle {
    /// @notice Last successful decoded response body (empty if last fulfill had `err`).
    string public lastResponse;

    /// @notice Raw error bytes from the last fulfill (`0x` on success).
    bytes public lastError;

    /// @notice Request id of the last fulfill callback.
    bytes32 public lastFulfilledId;

    event DataRequested(bytes32 indexed requestId, string query);
    event DataReceived(bytes32 indexed requestId, string response, bytes err);

    /**
     * @param router_ Live `CvmRouter` (Base Sepolia: see `deployments/base-sepolia-oracle.json`).
     * @param fulfillGasLimit_ Callback gas for `_fulfillRequest` (e.g. 300_000).
     */
    constructor(address router_, uint32 fulfillGasLimit_) Oracle(router_, CvmJob.TestFetch, fulfillGasLimit_) { }

    /// @notice Open a `TestFetch` request. `query` is forwarded as job args (URL / id / note).
    function request(string calldata query) external returns (bytes32 requestId) {
        requestId = _sendOracleRequest(abi.encode(query));
        emit DataRequested(requestId, query);
    }

    /// @inheritdoc Oracle
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        lastFulfilledId = requestId;
        lastError = err;

        if (err.length == 0 && response.length > 0) {
            lastResponse = abi.decode(response, (string));
        } else {
            lastResponse = "";
        }

        emit DataReceived(requestId, lastResponse, err);
    }
}
