// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PbrSettleJob, PbrSettleResult } from "@types/data/PbrSettleTypes.sol";

/**
 * @title IPbrSettle
 * @notice Phala + Succinct 3-phase PBR settlement pipeline.
 * @dev Phase 1 ingest (DMS digest) → phase 2 prove submit → phase 3 settle + verify.
 */
interface IPbrSettle {
    function KIND_INGEST() external view returns (bytes32);
    function KIND_PROVE() external view returns (bytes32);
    function KIND_SETTLE() external view returns (bytes32);

    function jobId(bytes32 tournamentId, uint16 season, uint32 roundNumber) external pure returns (bytes32);

    function startIngest(
        bytes32 tournamentId,
        uint16 season,
        uint32 roundNumber,
        bytes32 sourceId
    ) external returns (bytes32 id, bytes32 ingestRequestId);

    function applyToTreasury(bytes32 id) external;

    function getJob(bytes32 id) external view returns (PbrSettleJob memory);

    function getResult(bytes32 id) external view returns (PbrSettleResult memory);

    function isVkAllowed(bytes32 vkId) external view returns (bool);
}
