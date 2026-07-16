// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IProofVerifier
 * @notice Minimal interface for ZK / attestation gates on Class-1 executors.
 * @dev Concrete verifiers (PPM, eligibility, activity) live outside this package and are
 *      plugged in via `DelayedBatchExecutor.setProofVerifier`. A successful verify must
 *      guarantee integrity of the attested claim; liveness remains HP-operated.
 *
 *      Typical publicInputs encoding is verifier-specific (fixture digests, criteria epoch,
 *      playerId, action selector, etc.).
 */
interface IProofVerifier {
    /**
     * @notice Verifies a proof for a proposed action batch.
     * @param proof Opaque proof bytes (zkVM wrapper proof, etc.).
     * @param publicInputs ABI-encoded public inputs bound to the batch.
     * @return verified True if the proof is valid for `publicInputs`.
     */
    function verify(bytes calldata proof, bytes calldata publicInputs) external view returns (bool verified);
}
