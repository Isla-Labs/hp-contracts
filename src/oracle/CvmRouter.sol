// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/utils/Pausable.sol";

import { AccessRoles as Roles } from "@roles/AccessRoles.sol";
import { CvmErrors as Errors } from "@errors/oracle/CvmErrors.sol";
import { CvmEvents as Events } from "@events/oracle/CvmEvents.sol";
import { ICvmClient } from "@interfaces/oracle/ICvmClient.sol";
import { ICvmCoordinator } from "@interfaces/oracle/ICvmCoordinator.sol";
import { ICvmRouter } from "@interfaces/oracle/ICvmRouter.sol";
import { CvmCommitment, CvmJob, CvmRouterConfig } from "@types/oracle/CvmTypes.sol";

/**
 * @title CvmRouter
 * @notice Chainlink Functions-style request bus backed by a Phala Cloud CVM (not a DON).
 * @dev Flow:
 *        1. Consumer `sendRequest` → store commitment, emit `RequestStart`
 *        2. Attested CVM watches the event, runs the fixed `CvmJob` script
 *        3. Registered transmitter `fulfill` → callback `handleOracleFulfillment`
 *
 *      Fulfill is gated by `coordinator.isOracle(msg.sender)`. Listening to events is public;
 *      only KMS-backed transmitters registered on the coordinator may return data.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract CvmRouter is AccessControl, Pausable, ICvmRouter {
    // --------------------------------------------
    //  Constants
    // --------------------------------------------

    /// @dev Selector + 4 words — same budget as Functions Router (avoid OOG griefing).
    uint16 public constant MAX_CALLBACK_RETURN_BYTES = 4 + 4 * 32;

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    ICvmCoordinator private immutable _coordinator;

    CvmRouterConfig private _config;
    uint256 private _requestCount;

    mapping(bytes32 requestId => CvmCommitment) private _commitments;

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /**
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE`.
     * @param constitutional_ `ConstitutionalTimelock` — `CATEGORY_ONE` (config / pause).
     * @param coordinator_ `CvmCoordinator` used for `isOracle` checks.
     * @param config_ Initial router config.
     */
    constructor(address dao_, address constitutional_, address coordinator_, CvmRouterConfig memory config_) {
        if (dao_ == address(0) || constitutional_ == address(0) || coordinator_ == address(0)) {
            revert Errors.ZeroAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_ONE, constitutional_);

        _coordinator = ICvmCoordinator(coordinator_);
        _setConfig(config_);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc ICvmRouter
    function coordinator() public view returns (address) {
        return address(_coordinator);
    }

    /// @inheritdoc ICvmRouter
    function getConfig() external view returns (CvmRouterConfig memory) {
        return _config;
    }

    /// @inheritdoc ICvmRouter
    function getCommitment(bytes32 requestId) external view returns (CvmCommitment memory) {
        return _commitments[requestId];
    }

    /// @inheritdoc ICvmRouter
    function isPending(bytes32 requestId) public view returns (bool) {
        return _commitments[requestId].requester != address(0);
    }

    // --------------------------------------------
    //  Requests
    // --------------------------------------------

    /// @inheritdoc ICvmRouter
    function sendRequest(
        CvmJob job,
        bytes calldata args,
        uint32 callbackGasLimit
    ) external whenNotPaused returns (bytes32 requestId) {
        if (job == CvmJob.None) revert Errors.InvalidJob(job);

        CvmRouterConfig memory config = _config;
        if (callbackGasLimit > config.maxCallbackGasLimit) {
            revert Errors.CallbackGasLimitTooHigh(callbackGasLimit, config.maxCallbackGasLimit);
        }

        uint256 nonce;
        unchecked {
            nonce = ++_requestCount;
        }

        requestId = keccak256(abi.encode(block.chainid, address(this), msg.sender, nonce, job, keccak256(args)));
        if (_commitments[requestId].requester != address(0)) {
            revert Errors.DuplicateRequestId(requestId);
        }

        uint64 timeoutAt = uint64(block.timestamp) + config.requestTimeout;
        _commitments[requestId] = CvmCommitment({
            requester: msg.sender,
            job: job,
            argsHash: keccak256(args),
            callbackGasLimit: callbackGasLimit,
            timeoutAt: timeoutAt
        });

        emit Events.RequestStart({
            requestId: requestId,
            requester: msg.sender,
            requestInitiator: tx.origin,
            job: job,
            args: args,
            callbackGasLimit: callbackGasLimit,
            timeoutAt: timeoutAt
        });
    }

    // --------------------------------------------
    //  Fulfill
    // --------------------------------------------

    /// @inheritdoc ICvmRouter
    function fulfill(bytes32 requestId, bytes calldata response, bytes calldata err) external whenNotPaused {
        if (!_coordinator.isOracle(msg.sender)) revert Errors.OnlyOracle(msg.sender);

        CvmCommitment memory commitment = _commitments[requestId];
        if (commitment.requester == address(0)) revert Errors.UnknownRequest(requestId);
        if (block.timestamp > commitment.timeoutAt) revert Errors.RequestTimedOut(requestId);

        delete _commitments[requestId];

        (bool success,, bytes memory returnData) =
            _callback(requestId, response, err, commitment.callbackGasLimit, commitment.requester);

        emit Events.RequestProcessed({
            requestId: requestId,
            requester: commitment.requester,
            transmitter: msg.sender,
            callbackSuccess: success,
            response: response,
            err: err,
            callbackReturnData: returnData
        });
    }

    /// @inheritdoc ICvmRouter
    function cancelRequest(bytes32 requestId) external {
        CvmCommitment memory commitment = _commitments[requestId];
        if (commitment.requester == address(0)) revert Errors.UnknownRequest(requestId);
        if (msg.sender != commitment.requester) revert Errors.OnlyRequester(msg.sender);
        if (block.timestamp <= commitment.timeoutAt) revert Errors.RequestNotTimedOut(requestId);

        delete _commitments[requestId];
        emit Events.RequestCancelled(requestId, msg.sender);
    }

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    function updateConfig(CvmRouterConfig calldata config_) external onlyRole(Roles.CATEGORY_ONE) {
        _setConfig(config_);
    }

    function pause() external onlyRole(Roles.CATEGORY_ONE) {
        _pause();
    }

    function unpause() external onlyRole(Roles.CATEGORY_ONE) {
        _unpause();
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _setConfig(CvmRouterConfig memory config_) internal {
        if (config_.maxCallbackGasLimit == 0 || config_.requestTimeout == 0 || config_.gasForCallExactCheck == 0) {
            revert Errors.InvalidConfig();
        }
        _config = config_;
        emit Events.ConfigUpdated(config_);
    }

    /**
     * @dev Exact-gas callback patterned after Functions Router `_callback`.
     *      Failures in the consumer do not revert fulfill — they surface via `callbackSuccess`.
     */
    function _callback(
        bytes32 requestId,
        bytes memory response,
        bytes memory err,
        uint32 callbackGasLimit,
        address client
    ) internal returns (bool success, uint256 gasUsed, bytes memory returnData) {
        uint256 codeSize;
        assembly ("memory-safe") {
            codeSize := extcodesize(client)
        }
        if (codeSize == 0) {
            return (false, 0, new bytes(0));
        }

        bytes memory payload =
            abi.encodeWithSelector(ICvmClient.handleOracleFulfillment.selector, requestId, response, err);

        uint16 gasForCallExactCheck = _config.gasForCallExactCheck;
        returnData = new bytes(MAX_CALLBACK_RETURN_BYTES);

        assembly ("memory-safe") {
            let g := gas()
            if lt(g, gasForCallExactCheck) { revert(0, 0) }
            g := sub(g, gasForCallExactCheck)
            // EIP-150: ensure callbackGasLimit fits in 63/64 of remaining gas.
            if iszero(gt(sub(g, div(g, 64)), callbackGasLimit)) { revert(0, 0) }

            let gasBefore := gas()
            success := call(callbackGasLimit, client, 0, add(payload, 0x20), mload(payload), 0, 0)
            gasUsed := sub(gasBefore, gas())

            let toCopy := returndatasize()
            if gt(toCopy, MAX_CALLBACK_RETURN_BYTES) { toCopy := MAX_CALLBACK_RETURN_BYTES }
            mstore(returnData, toCopy)
            returndatacopy(add(returnData, 0x20), 0, toCopy)
        }
    }
}
