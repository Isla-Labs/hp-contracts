// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { Pausable } from "@openzeppelin/utils/Pausable.sol";

import { CvmErrors as Errors } from "@errors/oracle/CvmErrors.sol";
import { CvmEvents as Events } from "@events/oracle/CvmEvents.sol";
import { ICvmClient } from "@interfaces/oracle/ICvmClient.sol";
import { ICvmCoordinator } from "@interfaces/oracle/ICvmCoordinator.sol";
import { ICvmRouter } from "@interfaces/oracle/ICvmRouter.sol";
import { CvmCommitment, CvmJob, CvmRouterConfig } from "@types/oracle/CvmTypes.sol";

/**
 * @title CvmRouter
 * @notice Request bus for Phala CVM oracles (soft assignee + single fulfill).
 * @dev Intended behind `TransparentUpgradeableProxy` so sealed CVM env can keep a stable
 *      `CVM_ROUTER` across logic upgrades. Assignee exclusive windows are per-`CvmJob`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract CvmRouter is Initializable, Ownable, Pausable, ICvmRouter {
    // --------------------------------------------
    //  Constants
    // --------------------------------------------

    uint16 public constant MAX_CALLBACK_RETURN_BYTES = 4 + 4 * 32;

    /// @dev Default exclusive windows (HTTP-ish jobs ~60s; DMS batches 3m; SettleDms + zk 15m).
    uint32 private constant _EXCLUSIVE_FAST = 60;
    uint32 private constant _EXCLUSIVE_HISTORICAL_DMS = 3 minutes;
    uint32 private constant _EXCLUSIVE_SETTLE_DMS = 15 minutes;

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    ICvmCoordinator private _coordinator;

    CvmRouterConfig private _config;
    uint256 private _requestCount;

    mapping(bytes32 requestId => CvmCommitment) private _commitments;
    mapping(CvmJob job => uint32 exclusiveSeconds) private _jobExclusiveSeconds;

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    /**
     * @param owner_ Orchestrator / deployer — pause + config + coordinator swaps.
     * @param coordinator_ `CvmCoordinator` proxy used for `isOracle` / oracle set.
     * @param config_ Initial router config.
     */
    function initialize(
        address owner_,
        address coordinator_,
        CvmRouterConfig calldata config_
    ) external initializer {
        if (owner_ == address(0) || coordinator_ == address(0)) {
            revert Errors.ZeroAddress();
        }

        _transferOwnership(owner_);

        _coordinator = ICvmCoordinator(coordinator_);
        _setConfig(config_);
        _setDefaultJobExclusives();
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
    function jobExclusiveSeconds(CvmJob job) external view returns (uint32) {
        return _jobExclusiveSeconds[job];
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
    function sendRequest(CvmJob job, bytes calldata args) external whenNotPaused returns (bytes32 requestId) {
        if (job == CvmJob.None) revert Errors.InvalidJob(job);

        CvmRouterConfig memory config = _config;
        uint32 callbackGasLimit = config.maxCallbackGasLimit;

        uint32 exclusiveSeconds = _jobExclusiveSeconds[job];
        if (exclusiveSeconds == 0 || exclusiveSeconds > config.requestTimeout) {
            revert Errors.InvalidConfig();
        }

        uint256 nonce;
        unchecked {
            nonce = ++_requestCount;
        }

        requestId = keccak256(abi.encode(block.chainid, address(this), msg.sender, nonce, job, keccak256(args)));
        if (_commitments[requestId].requester != address(0)) {
            revert Errors.DuplicateRequestId(requestId);
        }

        address assignee = _pickAssignee(requestId);
        if (assignee == address(0)) revert Errors.NoLiveOracle();

        uint64 timeoutAt = uint64(block.timestamp) + config.requestTimeout;
        uint64 exclusiveUntil = uint64(block.timestamp) + exclusiveSeconds;
        if (exclusiveUntil > timeoutAt) exclusiveUntil = timeoutAt;

        _commitments[requestId] = CvmCommitment({
            requester: msg.sender,
            job: job,
            argsHash: keccak256(args),
            callbackGasLimit: callbackGasLimit,
            timeoutAt: timeoutAt,
            assignee: assignee,
            exclusiveUntil: exclusiveUntil
        });

        emit Events.RequestStart({
            requestId: requestId,
            requester: msg.sender,
            requestInitiator: tx.origin,
            job: job,
            args: args,
            callbackGasLimit: callbackGasLimit,
            timeoutAt: timeoutAt,
            assignee: assignee,
            exclusiveUntil: exclusiveUntil
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
        if (block.timestamp <= commitment.exclusiveUntil && msg.sender != commitment.assignee) {
            revert Errors.OnlyAssignee(commitment.assignee, msg.sender);
        }

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

    function updateConfig(CvmRouterConfig calldata config_) external onlyOwner {
        _setConfig(config_);
    }

    /// @notice Tune soft-assignee exclusive window for a job (must be > 0 and ≤ `requestTimeout`).
    function setJobExclusiveSeconds(CvmJob job, uint32 exclusiveSeconds) external onlyOwner {
        if (job == CvmJob.None) revert Errors.InvalidJob(job);
        _setJobExclusive(job, exclusiveSeconds);
    }

    /// @notice Seed / refresh default per-job exclusives (for upgrades that add the mapping).
    function seedDefaultJobExclusives() external onlyOwner {
        _setDefaultJobExclusives();
    }

    /// @notice Point at a new coordinator proxy (rare; same-chain registry swap).
    function setCoordinator(address coordinator_) external onlyOwner {
        if (coordinator_ == address(0)) revert Errors.ZeroAddress();
        _coordinator = ICvmCoordinator(coordinator_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
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

    function _setDefaultJobExclusives() internal {
        _setJobExclusive(CvmJob.TestFetch, _EXCLUSIVE_FAST);
        _setJobExclusive(CvmJob.PlayerMetadata, _EXCLUSIVE_FAST);
        _setJobExclusive(CvmJob.VanitySalts, _EXCLUSIVE_FAST);
        _setJobExclusive(CvmJob.SquadSync, _EXCLUSIVE_FAST);
        _setJobExclusive(CvmJob.RoundSync, _EXCLUSIVE_FAST);
        _setJobExclusive(CvmJob.SettleDms, _EXCLUSIVE_SETTLE_DMS);
        _setJobExclusive(CvmJob.HistoricalSquadSync, _EXCLUSIVE_FAST);
        _setJobExclusive(CvmJob.HistoricalRoundSync, _EXCLUSIVE_FAST);
        _setJobExclusive(CvmJob.HistoricalDms, _EXCLUSIVE_HISTORICAL_DMS);
        _setJobExclusive(CvmJob.FinalConfig, _EXCLUSIVE_FAST);
    }

    function _setJobExclusive(CvmJob job, uint32 exclusiveSeconds) internal {
        if (exclusiveSeconds == 0 || exclusiveSeconds > _config.requestTimeout) {
            revert Errors.InvalidConfig();
        }
        _jobExclusiveSeconds[job] = exclusiveSeconds;
        emit Events.JobExclusiveSecondsSet(job, exclusiveSeconds);
    }

    function _pickAssignee(bytes32 salt) internal view returns (address) {
        address[] memory all = _coordinator.oracles();
        uint256 n = all.length;
        if (n == 0) return address(0);

        uint256 start = uint256(salt) % n;
        for (uint256 i = 0; i < n;) {
            address cand = all[(start + i) % n];
            if (_coordinator.isOracle(cand)) return cand;
            unchecked {
                ++i;
            }
        }
        return address(0);
    }

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
