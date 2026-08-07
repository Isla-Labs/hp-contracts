// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { DeploymentsErrors as Errors } from "@errors/governance/DeploymentsErrors.sol";
import { DeploymentsEvents as Events } from "@events/governance/DeploymentsEvents.sol";
import { IDopplerConfig } from "@interfaces/governance/IDopplerConfig.sol";
import { DopplerTypes } from "@types/governance/DopplerTypes.sol";

import { CreateParams } from "@doppler/src/Airlock.sol";
import { FeeDistributionInfo, FeeRoutingMode } from "@doppler/src/types/RehypeTypes.sol";
import { WAD } from "@doppler/src/types/Wad.sol";

/**
 * @title DopplerConfig
 * @notice Standalone launch recipe + Doppler module wiring + `CreateParams` encoding for `DopplerLocker`.
 * @dev Ownable → Orchestrator. Locker reads config / buildCreateParams via external calls (keeps deploy path lean).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract DopplerConfig is Initializable, AddressBook, Ownable, IDopplerConfig {
    // -------------------------------------------------------------------------
    //  Launch recipe
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

    // -------------------------------------------------------------------------
    //  Module addresses
    // -------------------------------------------------------------------------

    address public tokenFactory;
    address public vaultFactory;
    address public airlock;
    address public governanceFactory;
    address public poolInitializer;
    address public liquidityMigrator;
    address public rehypeHookInitializer;
    address public rehypeHookMigrator;
    address public stakeVesting;
    address public hpTreasury;

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    /**
     * @notice Seed default launch recipe + resolve modules from AddressProvider; ownership → Orchestrator.
     */
    function initialize() external initializer {
        _applyLaunchConfig(DopplerTypes.defaultMarketLaunchConfig());

        tokenFactory = _getAddress(_addressKey(Addresses.DN404_FACTORY));
        vaultFactory = _getAddress(_addressKey(Addresses.PLAYER_VAULT_FACTORY));
        airlock = _getAddress(_addressKey(Addresses.DOPPLER_AIRLOCK));
        governanceFactory = _getAddress(_addressKey(Addresses.LAUNCHPAD_GOVERNANCE_FACTORY));
        poolInitializer = _getAddress(_addressKey(Addresses.DOPPLER_HOOK_INITIALIZER));
        liquidityMigrator = _getAddress(_addressKey(Addresses.DOPPLER_HOOK_MIGRATOR));
        rehypeHookInitializer = _getAddress(_addressKey(Addresses.REHYPE_DOPPLER_HOOK_INITIALIZER));
        rehypeHookMigrator = _getAddress(_addressKey(Addresses.REHYPE_DOPPLER_HOOK_MIGRATOR));
        stakeVesting = _getAddress(_addressKey(Addresses.STAKE_VESTING));
        hpTreasury = _getAddress(_addressKey(Addresses.HP_TREASURY));

        _transferOwnership(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));
    }

    // -------------------------------------------------------------------------
    //  Views
    // -------------------------------------------------------------------------

    /// @inheritdoc IDopplerConfig
    function bondingCurves() external view returns (DopplerTypes.Curve[] memory) {
        return _bondingCurves;
    }

    /// @inheritdoc IDopplerConfig
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

    /// @inheritdoc IDopplerConfig
    function dopplerModules(
        address feeRouterFactory_,
        address integrator_
    ) external view returns (DopplerTypes.DopplerModules memory) {
        return _dopplerModules(feeRouterFactory_, integrator_);
    }

    /// @inheritdoc IDopplerConfig
    function buildCreateParams(
        string calldata name,
        string calldata symbol,
        string calldata baseURI_,
        address feeRouter,
        bytes32 salt,
        address feeRouterFactory_,
        address integrator_
    ) external view returns (CreateParams memory) {
        return DopplerTypes.buildCreateParams(
            _dopplerModules(feeRouterFactory_, integrator_),
            marketLaunchConfig(),
            name,
            symbol,
            baseURI_,
            feeRouter,
            salt
        );
    }

    // -------------------------------------------------------------------------
    //  Admin — launch recipe
    // -------------------------------------------------------------------------

    /// @inheritdoc IDopplerConfig
    function setMarketLaunchConfig(DopplerTypes.MarketLaunchConfig memory config_) external onlyOwner {
        _applyLaunchConfig(config_);
        emit Events.MarketLaunchConfigUpdated(
            config_.initialSupply, config_.numTokensToSell, config_.farTick, config_.curves.length
        );
    }

    /// @inheritdoc IDopplerConfig
    function setBondingCurves(DopplerTypes.Curve[] memory curves_) external onlyOwner {
        _setBondingCurves(curves_);
        emit Events.BondingCurvesUpdated(curves_.length);
    }

    /// @inheritdoc IDopplerConfig
    function setGraduationPolicy(uint256 minGraduateProceeds_, uint32 minBondingDuration_) external onlyOwner {
        minGraduateProceeds = minGraduateProceeds_;
        minBondingDuration = minBondingDuration_;
        emit Events.GraduationPolicyUpdated(minGraduateProceeds_, minBondingDuration_);
    }

    /// @inheritdoc IDopplerConfig
    function setFeeDistribution(FeeDistributionInfo calldata feeDistribution_) external onlyOwner {
        _validateFeeDistribution(feeDistribution_);
        feeDistribution = feeDistribution_;
        emit Events.FeeDistributionUpdated();
    }

    // -------------------------------------------------------------------------
    //  Admin — modules
    // -------------------------------------------------------------------------

    /// @inheritdoc IDopplerConfig
    function configureDeployModules(address tokenFactory_, address vaultFactory_, address airlock_) external onlyOwner {
        if (tokenFactory_ == address(0) || vaultFactory_ == address(0) || airlock_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        tokenFactory = tokenFactory_;
        vaultFactory = vaultFactory_;
        airlock = airlock_;
        emit Events.DeployModulesConfigured(tokenFactory_, vaultFactory_, airlock_);
    }

    /// @inheritdoc IDopplerConfig
    function configureDopplerModules(
        address governanceFactory_,
        address poolInitializer_,
        address liquidityMigrator_,
        address rehypeHookInitializer_,
        address rehypeHookMigrator_
    ) external onlyOwner {
        if (
            governanceFactory_ == address(0) || poolInitializer_ == address(0) || liquidityMigrator_ == address(0)
                || rehypeHookInitializer_ == address(0) || rehypeHookMigrator_ == address(0)
        ) {
            revert Errors.ZeroAddress();
        }
        governanceFactory = governanceFactory_;
        poolInitializer = poolInitializer_;
        liquidityMigrator = liquidityMigrator_;
        rehypeHookInitializer = rehypeHookInitializer_;
        rehypeHookMigrator = rehypeHookMigrator_;
    }

    /// @inheritdoc IDopplerConfig
    function configureLaunchpadRecipients(address stakeVesting_, address hpTreasury_) external onlyOwner {
        if (stakeVesting_ == address(0) || hpTreasury_ == address(0)) revert Errors.ZeroAddress();
        stakeVesting = stakeVesting_;
        hpTreasury = hpTreasury_;
    }

    // -------------------------------------------------------------------------
    //  Internal
    // -------------------------------------------------------------------------

    function _dopplerModules(
        address feeRouterFactory_,
        address integrator_
    ) private view returns (DopplerTypes.DopplerModules memory m) {
        if (
            tokenFactory == address(0) || vaultFactory == address(0) || airlock == address(0)
                || governanceFactory == address(0) || poolInitializer == address(0) || liquidityMigrator == address(0)
                || rehypeHookInitializer == address(0) || rehypeHookMigrator == address(0)
                || stakeVesting == address(0) || hpTreasury == address(0)
        ) {
            revert Errors.NotConfigured();
        }
        if (feeRouterFactory_ == address(0) || integrator_ == address(0)) revert Errors.ZeroAddress();

        m.airlock = airlock;
        m.tokenFactory = tokenFactory;
        m.governanceFactory = governanceFactory;
        m.poolInitializer = poolInitializer;
        m.liquidityMigrator = liquidityMigrator;
        m.rehypeHookInitializer = rehypeHookInitializer;
        m.rehypeHookMigrator = rehypeHookMigrator;
        m.feeRouterFactory = feeRouterFactory_;
        m.numeraire = address(0); // native ETH — Airlock convention
        m.integrator = integrator_;
        m.airlockOwner = Ownable(airlock).owner();
        m.stakeVesting = stakeVesting;
        m.hpTreasury = hpTreasury;
    }

    function _applyLaunchConfig(DopplerTypes.MarketLaunchConfig memory config_) private {
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

    function _setBondingCurves(DopplerTypes.Curve[] memory curves_) private {
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

    function _validateFeeDistribution(FeeDistributionInfo memory dist) private pure {
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
