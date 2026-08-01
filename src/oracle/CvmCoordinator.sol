// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { EnumerableSet } from "@openzeppelin/utils/structs/EnumerableSet.sol";

import { AccessRoles as Roles } from "@roles/AccessRoles.sol";
import { CvmErrors as Errors } from "@errors/oracle/CvmErrors.sol";
import { CvmEvents as Events } from "@events/oracle/CvmEvents.sol";
import { IAttestationVerifier } from "@interfaces/oracle/IAttestationVerifier.sol";
import { ICvmCoordinator } from "@interfaces/oracle/ICvmCoordinator.sol";
import { IDstackApp } from "@interfaces/oracle/IDstackApp.sol";
import { AttestationClaim, OracleRegistration } from "@types/oracle/CvmTypes.sol";

/**
 * @title CvmCoordinator
 * @notice DstackApp owner facade + oracle registry with attestation-gated joins (Option C).
 * @dev Trust split:
 *        - DstackApp / Onchain KMS → boot-time composeHash + deviceId (keys only if allowed)
 *        - Attestation register → transmitter EOA bound to a fresh TEE quote + policy compose
 *        - `isOracle` → fulfill gate (active, unexpired, compose still allowed)
 *
 *      Permissionless: `registerOracle(attestation)` via `IAttestationVerifier`.
 *      Break-glass: `registerOracleBreakglass` / `addCvm` (CATEGORY_ONE), policy-exempt.
 *
 *      Latest-compose enforcement: remove compose from attestation policy → all registrations
 *      on that hash fail `isOracle` immediately (even before TTL), without restarting Phala.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 * @custom:see ./deviceRegistration.md
 */
contract CvmCoordinator is AccessControl, ICvmCoordinator {
    using EnumerableSet for EnumerableSet.AddressSet;

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    address private _dstackApp;
    IAttestationVerifier private _attestationVerifier;
    uint64 private _registrationTtl;

    EnumerableSet.AddressSet private _oracles;
    mapping(address transmitter => OracleRegistration) private _registration;
    mapping(address transmitter => bytes32 deviceId) private _deviceOf;
    mapping(bytes32 deviceId => address transmitter) private _transmitterOf;
    mapping(bytes32 composeHash => bool) private _composeAllowed;

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /**
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE`.
     * @param constitutional_ `ConstitutionalTimelock` — `CATEGORY_ONE` break-glass / devices.
     * @param dstackApp_ Optional Phala `DstackApp` (or set later).
     * @param attestationVerifier_ Optional `IAttestationVerifier` (required before permissionless join).
     * @param registrationTtl_ Live registration lifetime in seconds (re-attest to refresh).
     */
    constructor(
        address dao_,
        address constitutional_,
        address dstackApp_,
        address attestationVerifier_,
        uint64 registrationTtl_
    ) {
        if (dao_ == address(0) || constitutional_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (registrationTtl_ == 0) revert Errors.ZeroRegistrationTtl();

        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_ONE, constitutional_);

        _registrationTtl = registrationTtl_;
        emit Events.RegistrationTtlSet(registrationTtl_);

        if (dstackApp_ != address(0)) {
            _dstackApp = dstackApp_;
            emit Events.DstackAppSet(dstackApp_);
        }
        if (attestationVerifier_ != address(0)) {
            _attestationVerifier = IAttestationVerifier(attestationVerifier_);
            emit Events.AttestationVerifierSet(attestationVerifier_);
        }
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc ICvmCoordinator
    function dstackApp() public view returns (address) {
        return _dstackApp;
    }

    /// @inheritdoc ICvmCoordinator
    function attestationVerifier() public view returns (address) {
        return address(_attestationVerifier);
    }

    /// @inheritdoc ICvmCoordinator
    function registrationTtl() public view returns (uint64) {
        return _registrationTtl;
    }

    /// @inheritdoc ICvmCoordinator
    function isComposeAllowed(bytes32 composeHash) public view returns (bool) {
        return _composeAllowed[composeHash];
    }

    /// @inheritdoc ICvmCoordinator
    function getRegistration(address transmitter) external view returns (OracleRegistration memory) {
        return _registration[transmitter];
    }

    /// @inheritdoc ICvmCoordinator
    function isOracle(address transmitter) public view returns (bool) {
        OracleRegistration memory reg = _registration[transmitter];
        if (!reg.active) return false;
        if (block.timestamp > reg.expiresAt) return false;
        // Break-glass: composeHash == 0 skips policy. Attested joins require live policy membership.
        if (reg.composeHash != bytes32(0) && !_composeAllowed[reg.composeHash]) return false;
        return true;
    }

    /// @inheritdoc ICvmCoordinator
    function deviceOf(address transmitter) external view returns (bytes32) {
        return _deviceOf[transmitter];
    }

    /// @inheritdoc ICvmCoordinator
    function transmitterOf(bytes32 deviceId) external view returns (address) {
        return _transmitterOf[deviceId];
    }

    /// @inheritdoc ICvmCoordinator
    function oracles() external view returns (address[] memory) {
        return _oracles.values();
    }

    // --------------------------------------------
    //  Permissionless attestation join
    // --------------------------------------------

    /// @inheritdoc ICvmCoordinator
    function registerOracle(bytes calldata attestation) external {
        IAttestationVerifier verifier = _attestationVerifier;
        if (address(verifier) == address(0)) revert Errors.AttestationVerifierNotSet();

        AttestationClaim memory claim = verifier.verify(attestation);
        if (!_composeAllowed[claim.composeHash]) revert Errors.ComposeNotAllowed(claim.composeHash);

        uint64 expiresAt = uint64(block.timestamp) + _registrationTtl;
        _upsertRegistration(claim.deviceId, claim.transmitter, claim.composeHash, expiresAt);

        emit Events.OracleRegisteredWithAttestation(claim.transmitter, claim.deviceId, claim.composeHash, expiresAt);
    }

    // --------------------------------------------
    //  Break-glass / device ops (CATEGORY_ONE)
    // --------------------------------------------

    /// @inheritdoc ICvmCoordinator
    function addCvm(bytes32 deviceId, address transmitter) external onlyRole(Roles.CATEGORY_ONE) {
        _addDevice(deviceId);
        _upsertRegistration(deviceId, transmitter, bytes32(0), type(uint64).max);
        emit Events.OracleRegistered(transmitter, deviceId);
    }

    /// @inheritdoc ICvmCoordinator
    function removeCvm(bytes32 deviceId, address transmitter) external onlyRole(Roles.CATEGORY_ONE) {
        _revokeOracle(transmitter);
        _removeDevice(deviceId);
    }

    /// @inheritdoc ICvmCoordinator
    function registerOracleBreakglass(bytes32 deviceId, address transmitter) external onlyRole(Roles.CATEGORY_ONE) {
        _upsertRegistration(deviceId, transmitter, bytes32(0), type(uint64).max);
        emit Events.OracleRegistered(transmitter, deviceId);
    }

    /// @inheritdoc ICvmCoordinator
    function revokeOracle(address transmitter) external onlyRole(Roles.CATEGORY_ONE) {
        _revokeOracle(transmitter);
    }

    /// @inheritdoc ICvmCoordinator
    function addDevice(bytes32 deviceId) external onlyRole(Roles.CATEGORY_ONE) {
        _addDevice(deviceId);
    }

    /// @inheritdoc ICvmCoordinator
    function removeDevice(bytes32 deviceId) external onlyRole(Roles.CATEGORY_ONE) {
        _removeDevice(deviceId);
    }

    // --------------------------------------------
    //  Compose / policy governance (DAO)
    // --------------------------------------------

    /// @inheritdoc ICvmCoordinator
    function addComposeHash(bytes32 composeHash) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (composeHash == bytes32(0)) revert Errors.ZeroComposeHash();
        _app().addComposeHash(composeHash);
        _composeAllowed[composeHash] = true;
        emit Events.ComposeHashAdded(composeHash);
        emit Events.AttestationComposeAllowed(composeHash, true);
    }

    /// @inheritdoc ICvmCoordinator
    function removeComposeHash(bytes32 composeHash) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (composeHash == bytes32(0)) revert Errors.ZeroComposeHash();
        _app().removeComposeHash(composeHash);
        _composeAllowed[composeHash] = false;
        emit Events.ComposeHashRemoved(composeHash);
        emit Events.AttestationComposeAllowed(composeHash, false);
    }

    /// @inheritdoc ICvmCoordinator
    function setAttestationComposeAllowed(bytes32 composeHash, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (composeHash == bytes32(0)) revert Errors.ZeroComposeHash();
        _composeAllowed[composeHash] = allowed;
        emit Events.AttestationComposeAllowed(composeHash, allowed);
    }

    /// @inheritdoc ICvmCoordinator
    function setAllowAnyDevice(bool allowAny) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _app().setAllowAnyDevice(allowAny);
        emit Events.AllowAnyDeviceSet(allowAny);
    }

    /// @inheritdoc ICvmCoordinator
    function transferDstackAppOwnership(address newOwner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOwner == address(0)) revert Errors.ZeroAddress();
        _app().transferOwnership(newOwner);
    }

    /// @inheritdoc ICvmCoordinator
    function setAttestationVerifier(address verifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (verifier == address(0)) revert Errors.ZeroAddress();
        _attestationVerifier = IAttestationVerifier(verifier);
        emit Events.AttestationVerifierSet(verifier);
    }

    /// @inheritdoc ICvmCoordinator
    function setRegistrationTtl(uint64 ttl) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (ttl == 0) revert Errors.ZeroRegistrationTtl();
        _registrationTtl = ttl;
        emit Events.RegistrationTtlSet(ttl);
    }

    /// @notice Bind the Phala `DstackApp` this coordinator owns. One-shot.
    function setDstackApp(address dstackApp_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (dstackApp_ == address(0)) revert Errors.ZeroAddress();
        if (_dstackApp != address(0)) revert Errors.DstackAppAlreadySet();
        _dstackApp = dstackApp_;
        emit Events.DstackAppSet(dstackApp_);
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _app() internal view returns (IDstackApp app) {
        address appAddr = _dstackApp;
        if (appAddr == address(0)) revert Errors.DstackAppNotSet();
        app = IDstackApp(appAddr);
    }

    function _addDevice(bytes32 deviceId) internal {
        if (deviceId == bytes32(0)) revert Errors.ZeroDeviceId();
        _app().addDevice(deviceId);
        emit Events.DeviceAdded(deviceId);
    }

    function _removeDevice(bytes32 deviceId) internal {
        if (deviceId == bytes32(0)) revert Errors.ZeroDeviceId();
        address transmitter = _transmitterOf[deviceId];
        if (transmitter != address(0)) {
            _revokeOracle(transmitter);
        }
        _app().removeDevice(deviceId);
        emit Events.DeviceRemoved(deviceId);
    }

    function _upsertRegistration(
        bytes32 deviceId,
        address transmitter,
        bytes32 composeHash,
        uint64 expiresAt
    ) internal {
        if (deviceId == bytes32(0)) revert Errors.ZeroDeviceId();
        if (transmitter == address(0)) revert Errors.ZeroAddress();

        address existingOnDevice = _transmitterOf[deviceId];
        if (existingOnDevice != address(0) && existingOnDevice != transmitter) {
            _revokeOracle(existingOnDevice);
        }

        // If transmitter was bound to another device, clear that reverse index.
        bytes32 prevDevice = _deviceOf[transmitter];
        if (prevDevice != bytes32(0) && prevDevice != deviceId && _transmitterOf[prevDevice] == transmitter) {
            delete _transmitterOf[prevDevice];
        }

        _oracles.add(transmitter);
        _deviceOf[transmitter] = deviceId;
        _transmitterOf[deviceId] = transmitter;
        _registration[transmitter] =
            OracleRegistration({ deviceId: deviceId, composeHash: composeHash, expiresAt: expiresAt, active: true });
    }

    function _revokeOracle(address transmitter) internal {
        if (transmitter == address(0)) revert Errors.ZeroAddress();
        OracleRegistration memory reg = _registration[transmitter];
        if (!reg.active && !_oracles.contains(transmitter)) revert Errors.NotOracle(transmitter);

        bytes32 deviceId = _deviceOf[transmitter];
        _oracles.remove(transmitter);
        delete _deviceOf[transmitter];
        delete _registration[transmitter];
        if (_transmitterOf[deviceId] == transmitter) {
            delete _transmitterOf[deviceId];
        }
        emit Events.OracleRevoked(transmitter, deviceId);
    }
}
