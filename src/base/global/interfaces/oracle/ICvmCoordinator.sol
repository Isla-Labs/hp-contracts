// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { OracleRegistration } from "@types/oracle/CvmTypes.sol";

/**
 * @title ICvmCoordinator
 * @notice Attestation-gated oracle transmitter registry for the CVM bus (Base).
 * @dev Phala `DstackApp` / Onchain KMS live on Ethereum and are out of scope here.
 *      Fulfill gating (`isOracle`) requires an active registration whose `composeHash` is still
 *      in attestation policy and not past `expiresAt`.
 */
interface ICvmCoordinator {
    function attestationVerifier() external view returns (address);

    function registrationTtl() external view returns (uint64);

    function isOracle(address transmitter) external view returns (bool);

    function isComposeAllowed(bytes32 composeHash) external view returns (bool);

    function getRegistration(address transmitter) external view returns (OracleRegistration memory);

    function deviceOf(address transmitter) external view returns (bytes32);

    function transmitterOf(bytes32 deviceId) external view returns (address);

    function oracles() external view returns (address[] memory);

    /// @notice Deterministic live-oracle pick for request assignment (`salt` usually = requestId).
    function pickAssignee(bytes32 salt) external view returns (address);

    // --------------------------------------------
    //  Permissionless
    // --------------------------------------------

    function registerOracle(bytes calldata attestation) external;

    // --------------------------------------------
    //  Governance (DAO)
    // --------------------------------------------

    /// @notice Allowlist compose for attestation joins + `isOracle` (local policy only).
    function addComposeHash(bytes32 composeHash) external;

    /// @notice Remove compose from attestation policy (instant `isOracle` deny for that hash).
    function removeComposeHash(bytes32 composeHash) external;

    function setAttestationVerifier(address verifier) external;

    function setRegistrationTtl(uint64 ttl) external;
}
