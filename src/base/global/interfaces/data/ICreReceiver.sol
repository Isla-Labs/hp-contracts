// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IERC165 } from "@openzeppelin/utils/introspection/IERC165.sol";

/**
 * @title ICreReceiver
 * @notice Receives CRE / Keystone forwarder reports (Chainlink `IReceiver` equivalent).
 * @dev Implementations must advertise this interface via ERC165 so the forwarder can detect support.
 *      Production `KeystoneForwarder` delivers `metadata` as 64 bytes:
 *      `abi.encodePacked(workflowId, workflowName, workflowOwner)` (62 bytes) + `reportId` (2 bytes).
 */
interface ICreReceiver is IERC165 {
    /**
     * @notice Handles an incoming CRE workflow report.
     * @dev If this call reverts, the forwarder may retry with more gas. Discard stale reports in the consumer.
     * @param metadata Workflow identity (+ trailing `reportId` on production forwarders).
     * @param report ABI-encoded workflow payload.
     */
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
