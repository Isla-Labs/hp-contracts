// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PbrSettlePhase } from "@types/data/PbrSettleTypes.sol";

library PbrSettleEvents {
    event JobStarted(
        bytes32 indexed jobId,
        bytes32 indexed tournamentId,
        uint16 season,
        uint32 roundNumber,
        bytes32 sourceId,
        bytes32 ingestRequestId
    );

    event Ingested(bytes32 indexed jobId, bytes32 indexed digest, bytes32 sourceId, bytes32 proveRequestId);

    event ProveRequested(bytes32 indexed jobId, bytes32 proofRequestId, bytes32 vkId, bytes32 settleRequestId);

    event Settled(
        bytes32 indexed jobId,
        bytes32 indexed tournamentId,
        uint16 season,
        uint32 roundNumber,
        uint256 adjTotalPoints,
        uint256 vaultCount
    );

    event AppliedToTreasury(bytes32 indexed jobId, address indexed treasury, uint16 season, uint32 roundNumber);

    event JobFailed(bytes32 indexed jobId, PbrSettlePhase fromPhase, bytes reason);

    event VkAllowed(bytes32 indexed vkId, bool allowed);

    event ProofVerifierUpdated(address indexed previous, address indexed current);

    event AutoApplyUpdated(bool autoApply);
}
