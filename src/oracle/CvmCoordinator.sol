// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { EnumerableSet } from "@openzeppelin/utils/structs/EnumerableSet.sol";

import { CvmErrors as Errors } from "@errors/oracle/CvmErrors.sol";
import { CvmEvents as Events } from "@events/oracle/CvmEvents.sol";
import { IAttestationVerifier } from "@interfaces/oracle/IAttestationVerifier.sol";
import { ICvmCoordinator } from "@interfaces/oracle/ICvmCoordinator.sol";
import { AttestationClaim, OracleRegistration } from "@types/oracle/CvmTypes.sol";

/**
 * @title CvmCoordinator
 * @notice Attestation-gated oracle registry for the Base CVM bus.
 * @dev Hybrid layout: Phala Onchain KMS / `DstackApp` boot on Ethereum; this contract only
 *      gates who may `registerOracle` / `fulfill` on Base via TEE attestation + compose policy.
 *
 *      Intended behind `TransparentUpgradeableProxy` (stable address → no CVM sealed-env churn
 *      on logic upgrades). Owner / ProxyAdmin = Orchestrator (or deployer initially).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 * @custom:see ./deviceRegistration.md
 */
contract CvmCoordinator is Initializable, Ownable, ICvmCoordinator {
    using EnumerableSet for EnumerableSet.AddressSet;

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    /**
     * @param owner_ Orchestrator / deployer — compose policy, verifier, TTL.
     * @param attestationVerifier_ Optional; required before permissionless `registerOracle`.
     * @param registrationTtl_ Live registration lifetime in seconds.
     */
    function initialize(
        address owner_,
        address attestationVerifier_,
        uint64 registrationTtl_
    ) external initializer {
        if (owner_ == address(0)) revert Errors.ZeroAddress();
        if (registrationTtl_ == 0) revert Errors.ZeroRegistrationTtl();

        _transferOwnership(owner_);

        _registrationTtl = registrationTtl_;
        emit Events.RegistrationTtlSet(registrationTtl_);

        if (attestationVerifier_ != address(0)) {
            _attestationVerifier = IAttestationVerifier(attestationVerifier_);
            emit Events.AttestationVerifierSet(attestationVerifier_);
        }
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

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
        if (!_composeAllowed[reg.composeHash]) return false;
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

    /// @inheritdoc ICvmCoordinator
    function pickAssignee(bytes32 salt) public view returns (address) {
        uint256 n = _oracles.length();
        if (n == 0) return address(0);

        uint256 start = uint256(salt) % n;
        for (uint256 i = 0; i < n;) {
            address cand = _oracles.at((start + i) % n);
            if (isOracle(cand)) return cand;
            unchecked {
                ++i;
            }
        }
        return address(0);
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
    //  Compose / policy (owner)
    // --------------------------------------------

    /// @inheritdoc ICvmCoordinator
    function addComposeHash(bytes32 composeHash) external onlyOwner {
        if (composeHash == bytes32(0)) revert Errors.ZeroComposeHash();
        _composeAllowed[composeHash] = true;
        emit Events.ComposeHashAdded(composeHash);
        emit Events.AttestationComposeAllowed(composeHash, true);
    }

    /// @inheritdoc ICvmCoordinator
    function removeComposeHash(bytes32 composeHash) external onlyOwner {
        if (composeHash == bytes32(0)) revert Errors.ZeroComposeHash();
        _composeAllowed[composeHash] = false;
        emit Events.ComposeHashRemoved(composeHash);
        emit Events.AttestationComposeAllowed(composeHash, false);
    }

    /// @inheritdoc ICvmCoordinator
    function setAttestationVerifier(address verifier) external onlyOwner {
        if (verifier == address(0)) revert Errors.ZeroAddress();
        _attestationVerifier = IAttestationVerifier(verifier);
        emit Events.AttestationVerifierSet(verifier);
    }

    /// @inheritdoc ICvmCoordinator
    function setRegistrationTtl(uint64 ttl) external onlyOwner {
        if (ttl == 0) revert Errors.ZeroRegistrationTtl();
        _registrationTtl = ttl;
        emit Events.RegistrationTtlSet(ttl);
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

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
