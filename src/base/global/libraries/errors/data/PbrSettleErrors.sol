// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PbrSettlePhase } from "@types/data/PbrSettleTypes.sol";

library PbrSettleErrors {
    error ZeroAddress();
    error ZeroId();
    error ZeroDigest();
    error ZeroVk();
    error LengthMismatch();
    error ZeroMAdj();
    error JobExists(bytes32 jobId);
    error UnknownJob(bytes32 jobId);
    error BadPhase(bytes32 jobId, PbrSettlePhase actual, PbrSettlePhase expected);
    error UnknownKind(bytes32 kind);
    error VkNotAllowed(bytes32 vkId);
    error ProofRejected(bytes32 jobId);
    error AlreadyApplied(bytes32 jobId);
    error NotSettled(bytes32 jobId);
    error TreasuryMissing(bytes32 tournamentId);
    error EmptyVaults();
}
