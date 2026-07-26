// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/utils/math/Math.sol";

import { CreReceiver } from "@base/abstract/CreReceiver.sol";
import { IAppRegistry } from "@stabilityeth/interfaces/IAppRegistry.sol";
import { IPBRScoreOracle } from "@stabilityeth/interfaces/IPBRScoreOracle.sol";
import { IPBRTreasury } from "@stabilityeth/interfaces/IPBRTreasury.sol";
import { SETH } from "@stabilityeth/SETH.sol";

/**
 * @title PBRTreasury (SETH)
 * @notice Daily PBR distribution: pull fees, snapshot running scores from `PBRScoreOracle`, pull-claim.
 * @dev Separate CRE workflow from the 5m score oracle. Distribute report only supplies `epochId` +
 *      `appIds` to snapshot; weights come from the oracle (onchain-decayed running `m` / `s`).
 *
 *      Payout: `I_app = R * m / M_adj * s / S_adj`, then `payout = I_app * shareBps / 10_000`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PBRTreasury is Initializable, Ownable, CreReceiver, ReentrancyGuard, IPBRTreasury {
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Max unpaid epochs processed in one `claimAll` call (gas bound).
    uint256 public constant CLAIM_ALL_BATCH = 64;

    /// @notice Daily CRE payload — snapshots oracle scores; does not carry weights.
    struct DistributeReport {
        uint64 epochId;
        bytes32[] appIds;
    }

    struct Epoch {
        uint256 R;
        uint256 M_adj;
        uint256 S_adj;
        uint256 paid;
        uint64 settledAt;
        bool claimable;
    }

    SETH public seth;
    IAppRegistry public appRegistry;
    IPBRScoreOracle public scoreOracle;

    /// @notice Fees accrued since last epoch settle (ETH)
    uint256 public rewardsR;

    /// @notice Last settled epoch id (0 if none)
    uint64 public lastEpochId;

    mapping(uint64 epochId => Epoch) private _epochs;
    mapping(uint64 epochId => mapping(bytes32 appId => uint256)) public epochM;
    mapping(uint64 epochId => mapping(bytes32 appId => uint256)) public epochS;

    /// @dev claimedWords[keccak256(appId, beneficiary)][epochId >> 8]
    mapping(bytes32 claimKey => mapping(uint256 word => uint256)) public claimedWords;

    event FeesReceived(uint256 amount);
    event FeesPulled(uint256 amount);
    event EpochSettled(
        uint64 indexed epochId, uint256 R, uint256 M_adj, uint256 S_adj, uint256 appCount, uint64 settledAt
    );
    event ClaimPaid(
        uint64 indexed epochId, bytes32 indexed appId, address indexed beneficiary, uint256 payout
    );

    error ZeroAddress();
    error ZeroWorkflowId();
    error EmptyReport();
    error InvalidEpochId(uint64 received, uint64 expected);
    error InvalidScores();
    error EpochNotClaimable();
    error AlreadyClaimed();
    error NothingToClaim();
    error NotBeneficiary();
    error TransferFailed();
    error InsufficientEpochFunds();
    error DuplicateAppId(bytes32 appId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    /**
     * @param owner_ Admin (DAO / verifier stack).
     * @param seth_ StabilityETH wrapper (fee source).
     * @param appRegistry_ Verified app registry.
     * @param scoreOracle_ 5m running-score oracle.
     * @param forwarder_ CRE Keystone forwarder.
     * @param workflowId_ Distribute workflow id (daily).
     */
    function initialize(
        address owner_,
        address seth_,
        address appRegistry_,
        address scoreOracle_,
        address forwarder_,
        bytes32 workflowId_
    ) external initializer {
        if (
            owner_ == address(0) || seth_ == address(0) || appRegistry_ == address(0)
                || scoreOracle_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (workflowId_ == bytes32(0)) revert ZeroWorkflowId();

        _transferOwnership(owner_);
        __CreReceiver_init(forwarder_);
        _setExpectedWorkflowId(workflowId_);

        seth = SETH(payable(seth_));
        appRegistry = IAppRegistry(appRegistry_);
        scoreOracle = IPBRScoreOracle(scoreOracle_);
    }

    /// @dev Not nonReentrant — must accept ETH from `SETH.collectFees` while pull holds the guard.
    receive() external payable {
        if (msg.value == 0) return;
        rewardsR += msg.value;
        emit FeesReceived(msg.value);
    }

    // --------------------------------------------
    //  Fee intake
    // --------------------------------------------

    function pullFees(
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert NothingToClaim();
        seth.collectFees(address(this), amount);
        emit FeesPulled(amount);
    }

    function pullAllFees() public nonReentrant {
        uint256 amount = seth.feeAccrued();
        if (amount == 0) return;
        seth.collectFees(address(this), amount);
        emit FeesPulled(amount);
    }

    // --------------------------------------------
    //  CRE daily distribute
    // --------------------------------------------

    /// @inheritdoc CreReceiver
    function _processReport(bytes calldata, bytes calldata report) internal override {
        DistributeReport memory r = abi.decode(report, (DistributeReport));
        _settleEpoch(r);
    }

    // --------------------------------------------
    //  Claims
    // --------------------------------------------

    function claim(
        bytes32 appId,
        uint64 epochId,
        address beneficiary
    ) external nonReentrant returns (uint256 payout) {
        payout = _claim(appId, epochId, beneficiary);
    }

    /**
     * @notice Claim unpaid epochs for `beneficiary` from `fromEpoch` upward (gas-capped batch).
     * @return totalPayout Sum paid this call.
     * @return nextEpoch First epoch not fully scanned (resume cursor); `lastEpochId+1` if done.
     */
    function claimAll(
        bytes32 appId,
        address beneficiary,
        uint64 fromEpoch
    ) external nonReentrant returns (uint256 totalPayout, uint64 nextEpoch) {
        if (beneficiary == address(0)) revert ZeroAddress();

        address minter = appRegistry.minterOf(appId);
        if (msg.sender != beneficiary && msg.sender != minter) revert NotBeneficiary();
        if (!appRegistry.isBeneficiary(appId, beneficiary)) revert NotBeneficiary();

        uint64 last = lastEpochId;
        if (last == 0 || fromEpoch == 0 || fromEpoch > last) {
            return (0, last == 0 ? 1 : last + 1);
        }

        uint256 processed;
        nextEpoch = fromEpoch;

        while (nextEpoch <= last && processed < CLAIM_ALL_BATCH) {
            if (_epochs[nextEpoch].claimable && !_isClaimed(_claimKey(appId, beneficiary), nextEpoch)) {
                uint256 payout = _preview(appId, nextEpoch, beneficiary);
                if (payout > 0) {
                    totalPayout += _claimUnchecked(appId, nextEpoch, beneficiary);
                }
            }
            unchecked {
                ++nextEpoch;
                ++processed;
            }
        }
    }

    function previewClaim(
        bytes32 appId,
        uint64 epochId,
        address beneficiary
    ) external view returns (uint256 payout) {
        return _preview(appId, epochId, beneficiary);
    }

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    function setScoreOracle(
        address scoreOracle_
    ) external onlyOwner {
        if (scoreOracle_ == address(0)) revert ZeroAddress();
        scoreOracle = IPBRScoreOracle(scoreOracle_);
    }

    function setExpectedWorkflowId(
        bytes32 workflowId_
    ) external onlyOwner {
        if (workflowId_ == bytes32(0)) revert ZeroWorkflowId();
        _setExpectedWorkflowId(workflowId_);
    }

    function setForwarderAddress(
        address forwarder_
    ) external onlyOwner {
        _setForwarderAddress(forwarder_);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function getEpoch(
        uint64 epochId
    ) external view returns (Epoch memory) {
        return _epochs[epochId];
    }

    function isClaimed(bytes32 appId, address beneficiary, uint64 epochId) external view returns (bool) {
        return _isClaimed(_claimKey(appId, beneficiary), epochId);
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _settleEpoch(
        DistributeReport memory r
    ) internal {
        uint64 expected = lastEpochId + 1;
        if (r.epochId != expected) revert InvalidEpochId(r.epochId, expected);
        if (r.appIds.length == 0) revert EmptyReport();

        // Pull any pending SETH fees into rewardsR (via receive)
        uint256 pending = seth.feeAccrued();
        if (pending != 0) {
            seth.collectFees(address(this), pending);
            emit FeesPulled(pending);
        }

        uint256 M_adj;
        uint256 S_adj;
        uint256 accepted;
        uint256 len = r.appIds.length;

        for (uint256 i; i < len; ++i) {
            bytes32 appId = r.appIds[i];

            if (!appRegistry.isRegistered(appId) || !appRegistry.isActive(appId)) continue;
            if (appRegistry.netMinted(appId) == 0) continue;
            if (epochM[r.epochId][appId] != 0 || epochS[r.epochId][appId] != 0) {
                revert DuplicateAppId(appId);
            }

            (uint256 m, uint256 s,) = scoreOracle.getScores(appId);
            if (m == 0 || s == 0) continue;

            epochM[r.epochId][appId] = m;
            epochS[r.epochId][appId] = s;
            M_adj += m;
            S_adj += s;
            unchecked {
                ++accepted;
            }
        }

        if (accepted == 0 || M_adj == 0 || S_adj == 0) revert InvalidScores();

        uint256 R = rewardsR;
        if (R == 0) revert NothingToClaim();
        rewardsR = 0;

        Epoch storage epoch = _epochs[r.epochId];
        epoch.R = R;
        epoch.M_adj = M_adj;
        epoch.S_adj = S_adj;
        epoch.settledAt = uint64(block.timestamp);
        epoch.claimable = true;

        lastEpochId = r.epochId;

        emit EpochSettled(r.epochId, R, M_adj, S_adj, accepted, epoch.settledAt);
    }

    function _claim(
        bytes32 appId,
        uint64 epochId,
        address beneficiary
    ) internal returns (uint256 payout) {
        if (beneficiary == address(0)) revert ZeroAddress();

        address minter = appRegistry.minterOf(appId);
        if (msg.sender != beneficiary && msg.sender != minter) revert NotBeneficiary();
        if (!appRegistry.isBeneficiary(appId, beneficiary)) revert NotBeneficiary();

        return _claimUnchecked(appId, epochId, beneficiary);
    }

    /// @dev Caller already authenticated.
    function _claimUnchecked(
        bytes32 appId,
        uint64 epochId,
        address beneficiary
    ) internal returns (uint256 payout) {
        Epoch storage epoch = _epochs[epochId];
        if (!epoch.claimable) revert EpochNotClaimable();

        bytes32 key = _claimKey(appId, beneficiary);
        if (_isClaimed(key, epochId)) revert AlreadyClaimed();

        payout = _preview(appId, epochId, beneficiary);
        if (payout == 0) revert NothingToClaim();

        uint256 newPaid = epoch.paid + payout;
        if (newPaid > epoch.R) revert InsufficientEpochFunds();

        _setClaimed(key, epochId);
        epoch.paid = newPaid;

        (bool ok,) = beneficiary.call{ value: payout }("");
        if (!ok) revert TransferFailed();

        emit ClaimPaid(epochId, appId, beneficiary, payout);
    }

    function _preview(
        bytes32 appId,
        uint64 epochId,
        address beneficiary
    ) internal view returns (uint256 payout) {
        Epoch storage epoch = _epochs[epochId];
        if (!epoch.claimable) return 0;
        if (_isClaimed(_claimKey(appId, beneficiary), epochId)) return 0;

        uint16 shareBps = appRegistry.beneficiaryShareBps(appId, beneficiary);
        if (shareBps == 0) return 0;

        uint256 m = epochM[epochId][appId];
        uint256 s = epochS[epochId][appId];
        if (m == 0 || s == 0 || epoch.R == 0 || epoch.M_adj == 0 || epoch.S_adj == 0) return 0;

        uint256 appIncome = Math.mulDiv(Math.mulDiv(epoch.R, m, epoch.M_adj), s, epoch.S_adj);
        payout = Math.mulDiv(appIncome, shareBps, BPS_DENOMINATOR);
        uint256 remaining = epoch.R - epoch.paid;
        if (payout > remaining) payout = remaining;
    }

    function _claimKey(bytes32 appId, address beneficiary) internal pure returns (bytes32) {
        return keccak256(abi.encode(appId, beneficiary));
    }

    function _isClaimed(bytes32 claimKey, uint64 epochId) internal view returns (bool) {
        return (claimedWords[claimKey][epochId >> 8] & (uint256(1) << (epochId & 0xff))) != 0;
    }

    function _setClaimed(bytes32 claimKey, uint64 epochId) internal {
        claimedWords[claimKey][epochId >> 8] |= uint256(1) << (epochId & 0xff);
    }
}
