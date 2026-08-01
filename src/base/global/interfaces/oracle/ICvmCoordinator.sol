// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { OracleRegistration } from "@types/oracle/CvmTypes.sol";

/**
 * @title ICvmCoordinator
 * @notice DstackApp owner facade + oracle transmitter registry for the CVM bus.
 * @dev Fulfill gating (`isOracle`) requires an active registration whose `composeHash` is still
 *      in attestation policy (or break-glass with `composeHash == 0`) and not past `expiresAt`.
 */
interface ICvmCoordinator {
    function dstackApp() external view returns (address);

    function attestationVerifier() external view returns (address);

    function registrationTtl() external view returns (uint64);

    function isOracle(address transmitter) external view returns (bool);

    function isComposeAllowed(bytes32 composeHash) external view returns (bool);

    function getRegistration(address transmitter) external view returns (OracleRegistration memory);

    function deviceOf(address transmitter) external view returns (bytes32);

    function transmitterOf(bytes32 deviceId) external view returns (address);

    function oracles() external view returns (address[] memory);

    // --------------------------------------------
    //  Permissionless (Option C)
    // --------------------------------------------

    /// @notice Verify TEE attestation and register / refresh transmitter (TTL clock resets).
    function registerOracle(bytes calldata attestation) external;

    // --------------------------------------------
    //  Break-glass / bootstrap (CATEGORY_ONE)
    // --------------------------------------------

    function addCvm(bytes32 deviceId, address transmitter) external;

    function removeCvm(bytes32 deviceId, address transmitter) external;

    function registerOracleBreakglass(bytes32 deviceId, address transmitter) external;

    function revokeOracle(address transmitter) external;

    function addDevice(bytes32 deviceId) external;

    function removeDevice(bytes32 deviceId) external;

    // --------------------------------------------
    //  Governance
    // --------------------------------------------

    function addComposeHash(bytes32 composeHash) external;

    function removeComposeHash(bytes32 composeHash) external;

    function setAllowAnyDevice(bool allowAny) external;

    function transferDstackAppOwnership(address newOwner) external;

    function setAttestationVerifier(address verifier) external;

    function setRegistrationTtl(uint64 ttl) external;

    /// @notice Attestation policy: which compose hashes may hold a live `isOracle` registration.
    function setAttestationComposeAllowed(bytes32 composeHash, bool allowed) external;
}
