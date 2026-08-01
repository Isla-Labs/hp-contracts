// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title ICvmClient
 * @notice Callback surface that `CvmRouter` invokes on consumer contracts.
 */
interface ICvmClient {
    /**
     * @notice Router entrypoint after a successful oracle fulfill attempt.
     * @dev Either `response` or `err` is typically non-empty; both may be set by the CVM.
     */
    function handleOracleFulfillment(bytes32 requestId, bytes memory response, bytes memory err) external;
}
