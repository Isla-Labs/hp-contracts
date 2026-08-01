// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title CvmTypes
 * @notice Types for the Phala CVM oracle bus (Functions-style request → fulfill).
 * @dev Jobs are fixed allowlisted scripts inside the attested compose — not arbitrary source.
 */

/// @notice Which preconfigured CVM script to run for a request.
enum CvmJob {
    None,
    /// @dev Player name / metadata fetch (eligibility / listing surfaces).
    PlayerMetadata,
    /// @dev Matchweek player performance metrics (PPM) ingest helper.
    MatchweekPpm,
    /// @dev League/season squad sync for `EligibilityStore` (chunked club returns).
    SquadSync,
    /// @dev Sepolia smoke: CVM fetches a URL (or stub) and returns a string body.
    TestFetch
}

/// @notice Onchain commitment stored while a request is in flight.
struct CvmCommitment {
    /// @notice Consumer contract that opened the request (`msg.sender` of `sendRequest`).
    address requester;
    /// @notice Job the CVM must execute.
    CvmJob job;
    /// @notice `keccak256(args)` — args themselves live in the `RequestStart` event.
    bytes32 argsHash;
    /// @notice Gas limit forwarded to the consumer callback.
    uint32 callbackGasLimit;
    /// @notice Unix timestamp after which fulfill reverts and cancel is allowed.
    uint64 timeoutAt;
}

/// @notice Router runtime configuration.
struct CvmRouterConfig {
    /// @notice Upper bound for `callbackGasLimit` on new requests.
    uint32 maxCallbackGasLimit;
    /// @notice Request lifetime in seconds from `sendRequest`.
    uint32 requestTimeout;
    /// @notice Gas reserved to detect insufficient gas before the exact-gas callback (EIP-150).
    uint16 gasForCallExactCheck;
}

/// @notice Claim extracted from a TEE attestation used for permissionless oracle join.
/// @dev CVM binds `reportDataCommitment(transmitter, deviceId, composeHash, nonce)` into quote
///      `report_data`. Verifier must prove the quote and that binding.
struct AttestationClaim {
    address transmitter;
    bytes32 deviceId;
    bytes32 composeHash;
    /// @notice Freshness nonce mixed into report_data (anti-replay).
    bytes32 nonce;
    /// @notice Unix time asserted by the attestation / guest (verifier-enforced skew).
    uint64 quotedAt;
}

/// @notice Onchain oracle registration record (fulfill gate + compose freshness).
struct OracleRegistration {
    bytes32 deviceId;
    /// @notice Compose proven at registration; `bytes32(0)` = break-glass (policy-exempt).
    bytes32 composeHash;
    uint64 expiresAt;
    bool active;
}
