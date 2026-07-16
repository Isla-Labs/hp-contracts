// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";

import { GovernanceTypes } from "@governance/core/GovernanceTypes.sol";
import { IProofVerifier } from "@governance/core/IProofVerifier.sol";

/**
 * @title DelayedBatchExecutor
 * @notice Shared schedule → delay → execute engine for operational governance paths.
 * @dev Two entry paths:
 *      1. **Delayed (Class 2 / transitional Class 1):** `PROPOSER_ROLE` schedules a batch;
 *         anyone with `EXECUTOR_ROLE` (or open executor) runs it after `minDelay`.
 *      2. **Proof-gated (Class 1):** when `proofVerifier` is set, `executeWithProof` runs the
 *         batch immediately if the verifier accepts — integrity without a political vote.
 *
 *      `DEFAULT_ADMIN_ROLE` is the Aragon DAO (or a DAO-owned hub). Emergency cancel via
 *      `CANCELLER_ROLE` (Security Council / Multisig plugin acting as DAO).
 *
 *      Subclasses hold protocol roles (`LIFECYCLE_ROLE`, etc.) and expose typed helpers that
 *      encode `GovernanceTypes.Action[]` batches.
 */
abstract contract DelayedBatchExecutor is AccessControl, ReentrancyGuard {
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

    uint256 private constant _DONE = 1;

    /// @notice Minimum delay between schedule and execute (seconds)
    uint256 public minDelay;

    /// @notice Optional ZK / attestation gate for Class-1 immediate execution
    IProofVerifier public proofVerifier;

    /// @notice operationId → ready timestamp (`_DONE` once executed)
    mapping(bytes32 operationId => uint256 readyAt) private _readyAt;

    event MinDelayUpdated(uint256 previous, uint256 current);
    event ProofVerifierUpdated(address indexed previous, address indexed current);
    event BatchScheduled(
        bytes32 indexed operationId, uint256 indexed index, address target, uint256 value, bytes data, uint256 delay
    );
    event BatchSalt(bytes32 indexed operationId, bytes32 salt);
    event BatchExecuted(bytes32 indexed operationId, uint256 indexed index, address target, uint256 value, bytes data);
    event BatchCancelled(bytes32 indexed operationId);

    error ZeroAddress();
    error InvalidDelay(uint256 delay, uint256 minDelay_);
    error UnknownOperation(bytes32 operationId);
    error OperationNotReady(bytes32 operationId, uint256 readyAt, uint256 currentTime);
    error OperationExists(bytes32 operationId);
    error OperationAlreadyExecuted(bytes32 operationId);
    error ProofVerifierNotSet();
    error ProofRejected();
    error CallReverted(address target, bytes data);

    /**
     * @dev If `role` is granted to `address(0)`, any account may pass (OZ Timelock pattern).
     */
    modifier onlyRoleOrOpenRole(bytes32 role) {
        if (!hasRole(role, address(0))) {
            _checkRole(role);
        }
        _;
    }

    constructor(address admin_, uint256 minDelay_) {
        if (admin_ == address(0)) revert ZeroAddress();
        minDelay = minDelay_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        // Admin can cancel by default; DAO may also grant CANCELLER to council via role admin.
        _grantRole(CANCELLER_ROLE, admin_);
        // Open execution by default — anyone can finalize a matured batch (keepers / bots).
        _grantRole(EXECUTOR_ROLE, address(0));
    }

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    function setMinDelay(uint256 newMinDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 previous = minDelay;
        minDelay = newMinDelay;
        emit MinDelayUpdated(previous, newMinDelay);
    }

    function setProofVerifier(address verifier_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address previous = address(proofVerifier);
        proofVerifier = IProofVerifier(verifier_);
        emit ProofVerifierUpdated(previous, verifier_);
    }

    // --------------------------------------------
    //  Schedule / cancel / execute (delayed path)
    // --------------------------------------------

    /**
     * @notice Schedules a batch for execution after at least `minDelay`.
     * @param actions Targets/values/calldata to run as this contract (`address(this)` caller).
     * @param salt Salt for operation id uniqueness.
     * @param delay Delay in seconds; must be >= `minDelay`.
     * @return operationId Hash identifying the scheduled batch.
     */
    function schedule(
        GovernanceTypes.Action[] calldata actions,
        bytes32 salt,
        uint256 delay
    ) external onlyRole(PROPOSER_ROLE) returns (bytes32 operationId) {
        if (delay < minDelay) revert InvalidDelay(delay, minDelay);
        operationId = hashOperation(actions, salt);
        if (_readyAt[operationId] != 0) revert OperationExists(operationId);

        _readyAt[operationId] = block.timestamp + delay;

        for (uint256 i; i < actions.length; ++i) {
            emit BatchScheduled(operationId, i, actions[i].to, actions[i].value, actions[i].data, delay);
        }
        if (salt != bytes32(0)) emit BatchSalt(operationId, salt);
    }

    function cancel(bytes32 operationId) external onlyRole(CANCELLER_ROLE) {
        if (_readyAt[operationId] == 0 || _readyAt[operationId] == _DONE) revert UnknownOperation(operationId);
        delete _readyAt[operationId];
        emit BatchCancelled(operationId);
    }

    /**
     * @notice Executes a previously scheduled batch once the delay has elapsed.
     */
    function execute(GovernanceTypes.Action[] calldata actions, bytes32 salt)
        external
        onlyRoleOrOpenRole(EXECUTOR_ROLE)
        nonReentrant
    {
        bytes32 operationId = hashOperation(actions, salt);
        uint256 readyAt = _readyAt[operationId];
        if (readyAt == 0) revert UnknownOperation(operationId);
        if (readyAt == _DONE) revert OperationAlreadyExecuted(operationId);
        if (block.timestamp < readyAt) revert OperationNotReady(operationId, readyAt, block.timestamp);

        _readyAt[operationId] = _DONE;
        _executeBatch(operationId, actions);
    }

    // --------------------------------------------
    //  Proof path (Class 1)
    // --------------------------------------------

    /**
     * @notice Executes a batch immediately when `proofVerifier` accepts the proof.
     * @dev Does not consume a scheduled operation id. Use for ZK/data-gated lifecycle events.
     *      `publicInputs` must bind the batch (typically include `hashOperation(actions, salt)`).
     */
    function executeWithProof(
        GovernanceTypes.Action[] calldata actions,
        bytes32 salt,
        bytes calldata proof,
        bytes calldata publicInputs
    ) external nonReentrant {
        IProofVerifier verifier = proofVerifier;
        if (address(verifier) == address(0)) revert ProofVerifierNotSet();
        if (!verifier.verify(proof, publicInputs)) revert ProofRejected();

        bytes32 operationId = hashOperation(actions, salt);
        _executeBatch(operationId, actions);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function hashOperation(GovernanceTypes.Action[] calldata actions, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(actions, salt));
    }

    function getReadyAt(bytes32 operationId) external view returns (uint256) {
        return _readyAt[operationId];
    }

    function isOperationReady(bytes32 operationId) external view returns (bool) {
        uint256 readyAt = _readyAt[operationId];
        return readyAt > _DONE && block.timestamp >= readyAt;
    }

    function isOperationDone(bytes32 operationId) external view returns (bool) {
        return _readyAt[operationId] == _DONE;
    }

    // --------------------------------------------
    //  Internal
    // --------------------------------------------

    function _executeBatch(bytes32 operationId, GovernanceTypes.Action[] calldata actions) internal {
        for (uint256 i; i < actions.length; ++i) {
            GovernanceTypes.Action calldata action = actions[i];
            (bool ok, bytes memory returndata) = action.to.call{ value: action.value }(action.data);
            if (!ok) {
                if (returndata.length > 0) {
                    assembly ("memory-safe") {
                        revert(add(returndata, 0x20), mload(returndata))
                    }
                }
                revert CallReverted(action.to, action.data);
            }
            emit BatchExecuted(operationId, i, action.to, action.value, action.data);
        }
    }

    receive() external payable {}
}
