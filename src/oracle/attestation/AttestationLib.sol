// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AttestationClaim } from "@types/oracle/CvmTypes.sol";

/**
 * @title AttestationLib
 * @notice Shared helpers for quote report_data binding (CVM + onchain verifiers).
 */
library AttestationLib {
    /// @dev First 32 bytes of TDX/SGX REPORTDATA (64 bytes) hold this commitment.
    function reportDataCommitment(
        address transmitter,
        bytes32 deviceId,
        bytes32 composeHash,
        bytes32 nonce
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(transmitter, deviceId, composeHash, nonce));
    }

    function reportDataCommitment(AttestationClaim memory claim) internal pure returns (bytes32) {
        return reportDataCommitment(claim.transmitter, claim.deviceId, claim.composeHash, claim.nonce);
    }

    /// @notice Pack commitment into 64-byte REPORTDATA (commitment || nonce).
    function encodeReportData(AttestationClaim memory claim) internal pure returns (bytes memory reportData) {
        reportData = new bytes(64);
        bytes32 commitment = reportDataCommitment(claim);
        bytes32 nonce = claim.nonce;
        assembly ("memory-safe") {
            mstore(add(reportData, 0x20), commitment)
            mstore(add(reportData, 0x40), nonce)
        }
    }
}
