// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CvmErrors as Errors } from "@errors/oracle/CvmErrors.sol";
import { IAttestationVerifier } from "@interfaces/oracle/IAttestationVerifier.sol";
import { IAutomataDcapAttestation } from "@interfaces/oracle/IAutomataDcapAttestation.sol";
import { AttestationClaim } from "@types/oracle/CvmTypes.sol";
import { AttestationLib } from "./AttestationLib.sol";

/**
 * @title AutomataAttestationVerifier
 * @notice Production verifier: Automata DCAP + report_data claim binding from the raw quote.
 * @dev Attestation ABI:
 *        `abi.encode(AttestationClaim claim, bytes rawQuote)`
 *
 *      Flow:
 *        1. `dcap.verifyAndAttestOnChain(rawQuote)` must succeed
 *        2. Extract 64-byte REPORTDATA from the quote body (TDX V4 layout)
 *        3. Require first 32 bytes == `AttestationLib.reportDataCommitment(claim)`
 *        4. Enforce `quotedAt` freshness against `maxQuoteAge`
 *
 *      CVM must pass `AttestationLib.encodeReportData(claim)` into dstack `getQuote`.
 *      Coordinator still requires `composeHash` ∈ attestation policy (latest-compose gate).
 *
 * @custom:see https://docs.ata.network/tee-overview/tee-verifiers/intel-sgx-tdx-dcap/automata-dcap-attestation
 */
contract AutomataAttestationVerifier is IAttestationVerifier {
    using AttestationLib for AttestationClaim;

    uint64 public immutable maxQuoteAge;
    IAutomataDcapAttestation public immutable dcap;

    /// @dev Intel TDX Quote V4: 48-byte header, then TD report; REPORTDATA at +128 in report.
    uint256 public constant QUOTE_V4_HEADER_SIZE = 48;
    uint256 public constant TDX_REPORT_DATA_OFFSET = 128;

    mapping(bytes32 nonce => bool used) private _usedNonces;

    error DcapVerifyFailed(bytes reason);
    error ReportDataMismatch(bytes32 expected, bytes32 actual);
    error QuoteTooOld(uint64 quotedAt, uint64 maxAge);
    error QuoteFromFuture(uint64 quotedAt);
    error BadQuoteLength();
    error NonceAlreadyUsed(bytes32 nonce);

    constructor(address dcap_, uint64 maxQuoteAge_) {
        if (dcap_ == address(0)) revert Errors.ZeroAddress();
        if (maxQuoteAge_ == 0) revert Errors.InvalidConfig();
        dcap = IAutomataDcapAttestation(dcap_);
        maxQuoteAge = maxQuoteAge_;
    }

    /// @inheritdoc IAttestationVerifier
    function verify(bytes calldata attestation) external returns (AttestationClaim memory claim) {
        bytes memory rawQuote;
        (claim, rawQuote) = abi.decode(attestation, (AttestationClaim, bytes));

        _requireFresh(claim.quotedAt);
        if (claim.transmitter == address(0)) revert Errors.ZeroAddress();
        if (claim.deviceId == bytes32(0)) revert Errors.ZeroDeviceId();
        if (claim.composeHash == bytes32(0)) revert Errors.ZeroComposeHash();
        if (claim.nonce == bytes32(0)) revert Errors.InvalidConfig();
        if (_usedNonces[claim.nonce]) revert NonceAlreadyUsed(claim.nonce);

        (bool ok, bytes memory out) = dcap.verifyAndAttestOnChain(rawQuote);
        if (!ok) revert DcapVerifyFailed(out);

        bytes32 expected = claim.reportDataCommitment();
        bytes32 actual = _commitmentFromQuote(rawQuote);
        if (actual != expected) revert ReportDataMismatch(expected, actual);

        _usedNonces[claim.nonce] = true;
    }

    function _requireFresh(uint64 quotedAt) internal view {
        if (quotedAt > block.timestamp) revert QuoteFromFuture(quotedAt);
        if (block.timestamp - uint256(quotedAt) > maxQuoteAge) {
            revert QuoteTooOld(quotedAt, maxQuoteAge);
        }
    }

    function _commitmentFromQuote(bytes memory rawQuote) internal pure returns (bytes32 commitment) {
        uint256 start = QUOTE_V4_HEADER_SIZE + TDX_REPORT_DATA_OFFSET;
        if (rawQuote.length < start + 32) revert BadQuoteLength();
        assembly ("memory-safe") {
            commitment := mload(add(add(rawQuote, 0x20), start))
        }
    }
}
