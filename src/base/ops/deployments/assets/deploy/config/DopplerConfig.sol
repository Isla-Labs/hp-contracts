// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";

import { DeploymentsErrors as Errors } from "@errors/governance/DeploymentsErrors.sol";
import { DeploymentsEvents as Events } from "@events/governance/DeploymentsEvents.sol";

import { FeeDistributionInfo, FeeRoutingMode } from "@doppler/src/types/RehypeTypes.sol";
import { WAD } from "@doppler/src/types/Wad.sol";

import { DopplerTypes } from "@types/governance/DopplerTypes.sol";

/**
 * @title DopplerConfig
 * @notice Owner-updatable bonding / migrate launch parameters for `DopplerLocker`.
 * @dev `__DopplerConfig_init` seeds defaults from `DopplerTypes.defaultMarketLaunchConfig()`.
 *      Owner is the `Orchestrator`. HP graduation policy fields (`minGraduateProceeds`,
 *      `minBondingDuration`) are enforced by finalization logic (not by Doppler Airlock):
 *        - farTick reached anytime, OR
 *        - `raised ≥ minGraduateProceeds` after `launch + minBondingDuration`
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
abstract contract DopplerConfig is Ownable {
    // -------------------------------------------------------------------------
    //  Storage — shared across every player market until governance updates
    // -------------------------------------------------------------------------

    uint256 public initialSupply;
    uint256 public numTokensToSell;
    int24 public tickSpacing;
    int24 public farTick;

    uint24 public bondingLpFee;
    uint24 public rehypeStartFee;
    uint24 public rehypeEndFee;
    uint32 public rehypeFeeDurationSeconds;
    uint32 public rehypeStartingTime;
    FeeRoutingMode public feeRoutingMode;
    FeeDistributionInfo public feeDistribution;

    uint24 public migratorFee;
    bool public migratorUseDynamicFee;
    int24 public migratorTickSpacing;
    uint32 public migratorLockDuration;
    uint24 public migratorRehypeCustomFee;
    address public proceedsRecipient;
    uint256 public proceedsShare;

    /// @notice NFT metadata base URI for `DopplerDN404`.
    string public baseURI;

    /// @notice DN404 fungible→NFT unit (must divide `initialSupply`).
    uint256 public dn404Unit;

    /// @notice Soft ETH floor for the time-based graduation path.
    uint256 public minGraduateProceeds;

    /// @notice Minimum bonding age before the soft-floor graduation path opens.
    uint32 public minBondingDuration;

    DopplerTypes.Curve[] internal _bondingCurves;

    /// @dev Temporary Ownable owner on the implementation; proxy calls `__DopplerConfig_init`.
    constructor() Ownable(msg.sender) { }

    /// @notice Ownership → Orchestrator + default market launch config (proxy storage).
    function __DopplerConfig_init(address orchestrator_) internal {
        if (orchestrator_ == address(0)) revert Errors.ZeroAddress();
        _transferOwnership(orchestrator_);
        _applyLaunchConfig(DopplerTypes.defaultMarketLaunchConfig());
    }

    // -------------------------------------------------------------------------
    //  Views
    // -------------------------------------------------------------------------

    /// @notice Current bonding curves (copy).
    function bondingCurves() external view returns (DopplerTypes.Curve[] memory) {
        return _bondingCurves;
    }

    /// @notice Full launch config snapshot for encoders / offchain readers.
    function marketLaunchConfig() public view returns (DopplerTypes.MarketLaunchConfig memory config) {
        config.initialSupply = initialSupply;
        config.numTokensToSell = numTokensToSell;
        config.tickSpacing = tickSpacing;
        config.farTick = farTick;
        config.curves = _bondingCurves;
        config.bondingLpFee = bondingLpFee;
        config.rehypeStartFee = rehypeStartFee;
        config.rehypeEndFee = rehypeEndFee;
        config.rehypeFeeDurationSeconds = rehypeFeeDurationSeconds;
        config.rehypeStartingTime = rehypeStartingTime;
        config.feeRoutingMode = feeRoutingMode;
        config.feeDistribution = feeDistribution;
        config.migratorFee = migratorFee;
        config.migratorUseDynamicFee = migratorUseDynamicFee;
        config.migratorTickSpacing = migratorTickSpacing;
        config.migratorLockDuration = migratorLockDuration;
        config.migratorRehypeCustomFee = migratorRehypeCustomFee;
        config.proceedsRecipient = proceedsRecipient;
        config.proceedsShare = proceedsShare;
        config.baseURI = baseURI;
        config.dn404Unit = dn404Unit;
        config.minGraduateProceeds = minGraduateProceeds;
        config.minBondingDuration = minBondingDuration;
    }

    // -------------------------------------------------------------------------
    //  Owner setters
    // -------------------------------------------------------------------------

    /**
     * @notice Replace the full shared launch recipe (scalars + curves + graduation policy).
     * @dev Does not affect markets already deployed; only subsequent `Airlock.create` calls.
     */
    function setMarketLaunchConfig(DopplerTypes.MarketLaunchConfig memory config_) external onlyOwner {
        _applyLaunchConfig(config_);
        emit Events.MarketLaunchConfigUpdated(
            config_.initialSupply, config_.numTokensToSell, config_.farTick, config_.curves.length
        );
    }

    /// @notice Update multicurve segments only (shares must sum to WAD).
    function setBondingCurves(DopplerTypes.Curve[] memory curves_) external onlyOwner {
        _setBondingCurves(curves_);
        emit Events.BondingCurvesUpdated(curves_.length);
    }

    /// @notice Update HP soft-graduation policy (50 ETH / 30d defaults).
    function setGraduationPolicy(uint256 minGraduateProceeds_, uint32 minBondingDuration_) external onlyOwner {
        minGraduateProceeds = minGraduateProceeds_;
        minBondingDuration = minBondingDuration_;
        emit Events.GraduationPolicyUpdated(minGraduateProceeds_, minBondingDuration_);
    }

    /// @notice Update Rehype fee routing matrix (each source row must sum to WAD).
    function setFeeDistribution(FeeDistributionInfo calldata feeDistribution_) external onlyOwner {
        _validateFeeDistribution(feeDistribution_);
        feeDistribution = feeDistribution_;
        emit Events.FeeDistributionUpdated();
    }

    // -------------------------------------------------------------------------
    //  Internal
    // -------------------------------------------------------------------------

    function _applyLaunchConfig(DopplerTypes.MarketLaunchConfig memory config_) internal {
        if (config_.initialSupply == 0 || config_.numTokensToSell == 0) revert Errors.InvalidLaunchSupply();
        if (config_.numTokensToSell > config_.initialSupply) revert Errors.InvalidLaunchSupply();
        if (config_.tickSpacing <= 0) revert Errors.InvalidTickSpacing();
        if (config_.dn404Unit == 0 || config_.initialSupply % config_.dn404Unit != 0) {
            revert Errors.InvalidDN404Unit();
        }

        _validateFeeDistribution(config_.feeDistribution);
        _setBondingCurves(config_.curves);

        initialSupply = config_.initialSupply;
        numTokensToSell = config_.numTokensToSell;
        tickSpacing = config_.tickSpacing;
        farTick = config_.farTick;

        bondingLpFee = config_.bondingLpFee;
        rehypeStartFee = config_.rehypeStartFee;
        rehypeEndFee = config_.rehypeEndFee;
        rehypeFeeDurationSeconds = config_.rehypeFeeDurationSeconds;
        rehypeStartingTime = config_.rehypeStartingTime;
        feeRoutingMode = config_.feeRoutingMode;
        feeDistribution = config_.feeDistribution;

        migratorFee = config_.migratorFee;
        migratorUseDynamicFee = config_.migratorUseDynamicFee;
        migratorTickSpacing = config_.migratorTickSpacing;
        migratorLockDuration = config_.migratorLockDuration;
        migratorRehypeCustomFee = config_.migratorRehypeCustomFee;
        proceedsRecipient = config_.proceedsRecipient;
        proceedsShare = config_.proceedsShare;

        baseURI = config_.baseURI;
        dn404Unit = config_.dn404Unit;

        minGraduateProceeds = config_.minGraduateProceeds;
        minBondingDuration = config_.minBondingDuration;
    }

    function _setBondingCurves(DopplerTypes.Curve[] memory curves_) internal {
        uint256 length = curves_.length;
        if (length == 0) revert Errors.EmptyCurves();

        uint256 totalShares;
        for (uint256 i; i < length; ++i) {
            if (curves_[i].numPositions == 0 || curves_[i].shares == 0) revert Errors.InvalidCurve();
            if (curves_[i].tickLower >= curves_[i].tickUpper) revert Errors.InvalidCurve();
            totalShares += curves_[i].shares;
        }
        if (totalShares != WAD) revert Errors.InvalidCurveShares(totalShares);

        delete _bondingCurves;
        for (uint256 i; i < length; ++i) {
            _bondingCurves.push(curves_[i]);
        }
    }

    function _validateFeeDistribution(FeeDistributionInfo memory dist) internal pure {
        if (
            dist.assetFeesToAssetBuybackWad + dist.assetFeesToNumeraireBuybackWad + dist.assetFeesToBeneficiaryWad
                    + dist.assetFeesToLpWad != WAD
        ) {
            revert Errors.InvalidFeeDistribution();
        }
        if (
            dist.numeraireFeesToAssetBuybackWad + dist.numeraireFeesToNumeraireBuybackWad
                    + dist.numeraireFeesToBeneficiaryWad + dist.numeraireFeesToLpWad != WAD
        ) {
            revert Errors.InvalidFeeDistribution();
        }
    }
}
