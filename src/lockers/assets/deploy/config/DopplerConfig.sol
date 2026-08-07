// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DeploymentsErrors as Errors } from "@errors/governance/DeploymentsErrors.sol";

import { FeeDistributionInfo, FeeRoutingMode } from "@doppler/src/types/RehypeTypes.sol";
import { WAD } from "@doppler/src/types/Wad.sol";

import { DopplerTypes } from "@types/governance/DopplerTypes.sol";

/**
 * @title DopplerConfig
 * @notice Bonding / migrate launch parameters for `DopplerLocker`.
 * @dev `__DopplerConfig_init` seeds defaults from `DopplerTypes.defaultMarketLaunchConfig()`.
 *      Ownership / `onlyOwner` setters live on `DopplerLocker` (Orchestrator).
 *
 *      Create wiring (not stored here):
 *        - `LaunchpadGovernanceFactory` + `ExcessSupplyLocker` excess recipient
 *        - Bonding Rehype: 1% → FeeRouter 5:10:85 while `status == BONDING`
 *        - Spot Rehype: 1% → FeeRouter 5:5:90 for `GRADUATED` / `INACTIVE`
 *        - Spot pool LP fee: 0.15% (`migratorFee`) → StreamableFeesLocker 5:95 (airlock : HP)
 *        - Bonding beneficiaries stay empty (preserve `Airlock.migrate`)
 *
 *      Graduate migrate gate (`DopplerHookInitializer`): spot tick crosses `farTick` only
 *      (~2500 ETH FDV / ~$5M at $2000/ETH; open mark ~$500k). Tail share 10%.
 *      `minGraduateProceeds` / `minBondingDuration` are reserved storage — unused by Airlock.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
abstract contract DopplerConfig {
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

    /// @notice Legacy unused HTTPS prefix. Live `baseURI` comes from oracle IPFS at FinalConfig.
    string public baseURI;

    /// @notice DN404 fungible→NFT unit (must divide `initialSupply`).
    uint256 public dn404Unit;

    /// @notice Soft ETH floor for the time-based graduation path.
    uint256 public minGraduateProceeds;

    /// @notice Minimum bonding age before the soft-floor graduation path opens.
    uint32 public minBondingDuration;

    DopplerTypes.Curve[] internal _bondingCurves;

    /// @notice Seed default market launch config (proxy storage).
    function __DopplerConfig_init() internal {
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
