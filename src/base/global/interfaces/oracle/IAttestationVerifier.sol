// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AttestationClaim } from "@types/oracle/CvmTypes.sol";

/**
 * @title IAttestationVerifier
 * @notice Pluggable TEE attestation verifier for permissionless `CvmCoordinator` joins.
 * @dev Production: Automata DCAP / ZK-DCAP (+ dstack measurement guest). Tests: mock.
 *      Encoding of `attestation` is verifier-specific; see concrete implementations.
 */
interface IAttestationVerifier {
    /**
     * @notice Verify attestation bytes and return the bound registration claim.
     * @dev MUST revert if the quote / proof is invalid or the claim is not bound in report_data.
     */
    function verify(bytes calldata attestation) external returns (AttestationClaim memory claim);
}
