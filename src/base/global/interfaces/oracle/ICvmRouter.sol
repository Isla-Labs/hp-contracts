// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CvmCommitment, CvmJob, CvmRouterConfig } from "@types/oracle/CvmTypes.sol";

/**
 * @title ICvmRouter
 * @notice Request queue + fulfill relay for Phala CVM oracles.
 */
interface ICvmRouter {
    function coordinator() external view returns (address);

    function getConfig() external view returns (CvmRouterConfig memory);

    function getCommitment(bytes32 requestId) external view returns (CvmCommitment memory);

    function isPending(bytes32 requestId) external view returns (bool);

    /// @notice Open a request; emits `RequestStart` for CVM listeners.
    function sendRequest(
        CvmJob job,
        bytes calldata args,
        uint32 callbackGasLimit
    ) external returns (bytes32 requestId);

    /// @notice Oracle-only fulfill; callbacks `handleOracleFulfillment` on the requester.
    function fulfill(bytes32 requestId, bytes calldata response, bytes calldata err) external;

    /// @notice Requester may cancel after `timeoutAt`.
    function cancelRequest(bytes32 requestId) external;
}
