// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { CreReceiver } from "@base/abstract/CreReceiver.sol";
import { IAppRegistry } from "@stabilityeth/interfaces/IAppRegistry.sol";
import { IPBRScoreOracle } from "@stabilityeth/interfaces/IPBRScoreOracle.sol";

/**
 * @title PBRScoreOracle
 * @notice 5m CRE consumer: raw TVL + mint observations in, onchain EWMA / decay out.
 * @dev CRE pushes observations only. Decay and running scores are computed here.
 *      - `m`: EWMA of observed TVL
 *      - `s`: decay prior mint-weight, then add `ΔtotalMinted` since last checkpoint
 *
 *      Separate workflow id from `PBRTreasury` (daily distribute).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PBRScoreOracle is Initializable, Ownable, CreReceiver, IPBRScoreOracle {
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Raw observations for one 5m tick (CRE does not pre-weight).
    struct ObservationReport {
        bytes32[] appIds;
        uint256[] tvlRaw;
        /// @dev Observed cumulative `AppRegistry.totalMinted` (oracle diffs vs last checkpoint).
        uint256[] totalMintedObserved;
    }

    IAppRegistry public appRegistry;

    /// @notice Share of prior score retained each update (`α = 1 - decayBps/1e4` on TVL EWMA).
    uint16 public decayBps;

    mapping(bytes32 appId => uint256) public runningM;
    mapping(bytes32 appId => uint256) public runningS;
    mapping(bytes32 appId => uint256) public lastTotalMinted;
    mapping(bytes32 appId => uint64) public updatedAt;

    uint64 public lastReportAt;

    event ScoresUpdated(bytes32 indexed appId, uint256 m, uint256 s, uint256 tvlRaw, uint256 mintDelta);
    event DecayBpsUpdated(uint16 decayBps);
    event ObservationBatchProcessed(uint256 appCount, uint64 timestamp);

    error ZeroAddress();
    error ZeroWorkflowId();
    error LengthMismatch();
    error EmptyReport();
    error InvalidDecayBps();
    error DuplicateAppId(bytes32 appId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    /**
     * @param owner_ Admin.
     * @param appRegistry_ Verified app registry.
     * @param forwarder_ CRE Keystone forwarder.
     * @param workflowId_ Scores workflow id (5m).
     * @param decayBps_ Prior-score retention in bps (e.g. 9000 = 90% retain / 10% new TVL weight).
     */
    function initialize(
        address owner_,
        address appRegistry_,
        address forwarder_,
        bytes32 workflowId_,
        uint16 decayBps_
    ) external initializer {
        if (owner_ == address(0) || appRegistry_ == address(0)) revert ZeroAddress();
        if (workflowId_ == bytes32(0)) revert ZeroWorkflowId();
        if (decayBps_ >= BPS_DENOMINATOR) revert InvalidDecayBps();

        _transferOwnership(owner_);
        __CreReceiver_init(forwarder_);
        _setExpectedWorkflowId(workflowId_);

        appRegistry = IAppRegistry(appRegistry_);
        decayBps = decayBps_;
    }

    /// @inheritdoc CreReceiver
    function _processReport(bytes calldata, bytes calldata report) internal override {
        ObservationReport memory r = abi.decode(report, (ObservationReport));
        _applyObservations(r);
    }

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    function setDecayBps(
        uint16 decayBps_
    ) external onlyOwner {
        if (decayBps_ >= BPS_DENOMINATOR) revert InvalidDecayBps();
        decayBps = decayBps_;
        emit DecayBpsUpdated(decayBps_);
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

    function getScores(
        bytes32 appId
    ) external view returns (uint256 m, uint256 s, uint64 updatedAt_) {
        return (runningM[appId], runningS[appId], updatedAt[appId]);
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _applyObservations(
        ObservationReport memory r
    ) internal {
        uint256 len = r.appIds.length;
        if (len == 0) revert EmptyReport();
        if (len != r.tvlRaw.length || len != r.totalMintedObserved.length) revert LengthMismatch();

        uint16 decay = decayBps;
        uint16 alpha = uint16(BPS_DENOMINATOR - decay);
        uint64 ts = uint64(block.timestamp);

        // First pass: detect duplicates via temporary zeroing after read is awkward;
        // require CRE uniqueness by reverting if an app is updated twice in one report.
        for (uint256 i; i < len; ++i) {
            bytes32 appId = r.appIds[i];
            for (uint256 j; j < i; ++j) {
                if (r.appIds[j] == appId) revert DuplicateAppId(appId);
            }

            if (!appRegistry.isRegistered(appId) || !appRegistry.isActive(appId)) {
                continue;
            }

            // Unused minter: clear scores so daily settle cannot pay TVL-only apps
            if (appRegistry.netMinted(appId) == 0) {
                runningM[appId] = 0;
                runningS[appId] = 0;
                lastTotalMinted[appId] = r.totalMintedObserved[i];
                updatedAt[appId] = ts;
                emit ScoresUpdated(appId, 0, 0, r.tvlRaw[i], 0);
                continue;
            }

            uint256 prevM = runningM[appId];
            uint256 prevS = runningS[appId];
            uint256 tvl = r.tvlRaw[i];
            uint256 observedMinted = r.totalMintedObserved[i];
            uint256 prevMinted = lastTotalMinted[appId];
            uint256 mintDelta = observedMinted > prevMinted ? observedMinted - prevMinted : 0;

            // m: EWMA of TVL — m' = decay*m + alpha*tvl
            uint256 m = (prevM * decay + tvl * alpha) / BPS_DENOMINATOR;
            // s: decay prior weight, then add raw mint delta this tick
            uint256 s = (prevS * decay) / BPS_DENOMINATOR + mintDelta;

            runningM[appId] = m;
            runningS[appId] = s;
            lastTotalMinted[appId] = observedMinted;
            updatedAt[appId] = ts;

            emit ScoresUpdated(appId, m, s, tvl, mintDelta);
        }

        lastReportAt = ts;
        emit ObservationBatchProcessed(len, ts);
    }
}
