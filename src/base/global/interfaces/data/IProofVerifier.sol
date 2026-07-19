// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IProofVerifier
 * @notice Minimal interface for future ZK / attestation gates.
 * @dev Not wired into governance-2 day-one contracts. Reserved for later cat-3 caller
 *      restrictions on top of `UpdateAuthority` (or typed executors).
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
