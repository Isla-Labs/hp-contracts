// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CvmErrors as Errors } from "@errors/oracle/CvmErrors.sol";
import { IAttestationVerifier } from "@interfaces/oracle/IAttestationVerifier.sol";
import { AttestationClaim } from "@types/oracle/CvmTypes.sol";
import { AttestationLib } from "./AttestationLib.sol";

/**
 * @title MockAttestationVerifier
 * @notice Test / staging verifier: accepts abi-encoded `AttestationClaim` when `quotedAt` is fresh.
 * @dev Does **not** verify TEE quotes. Never use as production `attestationVerifier`.
 */
contract MockAttestationVerifier is IAttestationVerifier {
    using AttestationLib for AttestationClaim;

    uint64 public immutable maxQuoteAge;

    /// @notice Optional kill-switch for negative tests.
    bool public accept = true;

    error MockRejected();
    error QuoteTooOld(uint64 quotedAt, uint64 maxAge);
    error QuoteFromFuture(uint64 quotedAt);

    constructor(uint64 maxQuoteAge_) {
        if (maxQuoteAge_ == 0) revert Errors.InvalidConfig();
        maxQuoteAge = maxQuoteAge_;
    }

    function setAccept(bool accept_) external {
        accept = accept_;
    }

    /// @inheritdoc IAttestationVerifier
    function verify(bytes calldata attestation) external view returns (AttestationClaim memory claim) {
        if (!accept) revert MockRejected();
        claim = abi.decode(attestation, (AttestationClaim));

        if (claim.transmitter == address(0)) revert Errors.ZeroAddress();
        if (claim.deviceId == bytes32(0)) revert Errors.ZeroDeviceId();
        if (claim.composeHash == bytes32(0)) revert Errors.ZeroComposeHash();
        if (claim.quotedAt > block.timestamp) revert QuoteFromFuture(claim.quotedAt);
        if (block.timestamp - uint256(claim.quotedAt) > maxQuoteAge) {
            revert QuoteTooOld(claim.quotedAt, maxQuoteAge);
        }

        // Touch commitment helper so CVM packing stays covered in tests.
        if (claim.reportDataCommitment() == bytes32(0)) revert Errors.InvalidConfig();
    }
}
