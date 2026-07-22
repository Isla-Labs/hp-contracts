// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CreateParams } from "@doppler/Airlock.sol";
import {
    FeeDistributionInfo,
    FeeRoutingMode,
    InitData as RehypeBondingHookData,
    MigratorInitData as RehypeMigratorHookData
} from "@doppler/types/RehypeTypes.sol";
import { WAD } from "@doppler/types/Wad.sol";

import { EligibilityBucket } from "@src/data/eligibility/types/EligibilityTypes.sol";

/**
 * @title DopplerTypes
 * @notice Shared types + encoders for `Airlock.create` (Rehype multicurve path).
 * @dev Mutable launch parameters live on `DopplerConfig` (governance-updatable). This library
 *      holds ABI shapes, default constants, and pure encoders.
 *
 *      Default economic recipe (ETH FDV, asset-as-token0 tick orientation):
 *        - Supply: 22M total / 20M to sell
 *        - Fee: 1% (`10_000` millionths)
 *        - Spacing: 8
 *        - Curves (ETH FDV → tick, spacing-aligned):
 *            35%  300 → 900   (−112040 → −101040)
 *            35%  700 → 2000  (−103560 → −93056)
 *            20% 1800 → 4000  (−94120 → −86128)
 *            10% 4000 → max   (−86128 → 887272) tail
 *        - `farTick` = −86128 (~4000 ETH FDV / ~2000 ETH full-raise target)
 *        - HP graduation policy: farTick anytime, OR ≥50 ETH after 30 days
 *
 *      Fee matrix → FeeRouter (`buybackDst`):
 *        - ETH fees: direct (`numeraireFeesToNumeraireBuybackWad`)
 *        - Player-token fees: swap to ETH (`assetFeesToNumeraireBuybackWad`)
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
library DopplerTypes {
    // -------------------------------------------------------------------------
    //  Default constants
    // -------------------------------------------------------------------------

    uint256 internal constant DEFAULT_INITIAL_SUPPLY = 22_000_000 ether;
    uint256 internal constant DEFAULT_NUM_TOKENS_TO_SELL = 20_000_000 ether;

    int24 internal constant DEFAULT_TICK_SPACING = 8;

    /// @dev ~4000 ETH FDV (end of main discovery / start of tail).
    int24 internal constant DEFAULT_FAR_TICK = -86_128;

    /// @dev Uniswap V4 max tick (aligned to spacing 8).
    int24 internal constant DEFAULT_TAIL_TICK_UPPER = 887_272;

    /// @dev 1% in Uniswap V4 millionths.
    uint24 internal constant DEFAULT_FEE = 10_000;

    uint32 internal constant DEFAULT_MIGRATOR_LOCK_DURATION = 30 days;

    /// @dev Soft floor for time-based graduation (HP policy, not a Doppler field).
    uint256 internal constant DEFAULT_MIN_GRADUATE_PROCEEDS = 50 ether;

    /// @dev Earliest timestamp offset for the ≥50 ETH graduation path.
    uint32 internal constant DEFAULT_MIN_BONDING_DURATION = 30 days;

    /// @dev Doppler `MIN_PROTOCOL_OWNER_SHARES` = WAD / 20.
    uint96 internal constant PROTOCOL_OWNER_SHARES = uint96(WAD / 20);

    // -------------------------------------------------------------------------
    //  ABI-compatible local shapes (match Doppler layouts; avoid path-identity clashes)
    // -------------------------------------------------------------------------

    /// @dev Matches `Multicurve.Curve`.
    struct Curve {
        int24 tickLower;
        int24 tickUpper;
        uint16 numPositions;
        uint256 shares;
    }

    /// @dev Matches `BeneficiaryData`.
    struct Beneficiary {
        address beneficiary;
        uint96 shares;
    }

    /// @dev Matches `DopplerERC20V1.VestingSchedule` (empty arrays only today).
    struct VestingSchedule {
        uint64 cliff;
        uint64 duration;
    }

    // -------------------------------------------------------------------------
    //  Module wiring + shared launch config
    // -------------------------------------------------------------------------

    /**
     * @notice Whitelisted Doppler / HP module addresses used when building `CreateParams`.
     * @dev Set once on `DeployDoppler` (immutables or one-time setters).
     */
    struct DopplerModules {
        address airlock;
        address tokenFactory;
        address governanceFactory;
        address poolInitializer;
        address liquidityMigrator;
        address rehypeHookInitializer;
        address rehypeHookMigrator;
        address feeRouterFactory;
        address numeraire;
        address integrator;
        address airlockOwner;
    }

    /**
     * @notice Shared bonding + migrate parameters for every player market.
     * @dev Platform rule: all markets launch with the same curve / fee shape until governance
     *      updates `DopplerConfig`. `curves` must be contiguous/overlapping with shares = WAD.
     */
    struct MarketLaunchConfig {
        uint256 initialSupply;
        uint256 numTokensToSell;
        int24 tickSpacing;
        int24 farTick;
        Curve[] curves;
        uint24 bondingLpFee;
        uint24 rehypeStartFee;
        uint24 rehypeEndFee;
        uint32 rehypeFeeDurationSeconds;
        uint32 rehypeStartingTime;
        FeeRoutingMode feeRoutingMode;
        FeeDistributionInfo feeDistribution;
        uint24 migratorFee;
        bool migratorUseDynamicFee;
        int24 migratorTickSpacing;
        uint32 migratorLockDuration;
        uint24 migratorRehypeCustomFee;
        address proceedsRecipient;
        uint256 proceedsShare;
        string tokenURI;
        uint256 maxBalanceLimit;
        uint48 balanceLimitEnd;
        address balanceLimitController;
        uint256 minGraduateProceeds;
        uint32 minBondingDuration;
    }

    /**
     * @notice One waiting-room candidate (cohort + optional StatsPerform name/symbol).
     * @dev `metadataSet` flips true after Chainlink Functions fills `name` / `symbol`.
     */
    struct PendingEligible {
        bytes32 playerId;
        EligibilityBucket bucket;
        string name;
        string symbol;
        bool metadataSet;
    }

    // -------------------------------------------------------------------------
    //  Defaults
    // -------------------------------------------------------------------------

    /// @notice Recommended launch config (50–2000 ETH band, 1% fee, 4-curve multicurve).
    function defaultMarketLaunchConfig() internal pure returns (MarketLaunchConfig memory config) {
        config.initialSupply = DEFAULT_INITIAL_SUPPLY;
        config.numTokensToSell = DEFAULT_NUM_TOKENS_TO_SELL;
        config.tickSpacing = DEFAULT_TICK_SPACING;
        config.farTick = DEFAULT_FAR_TICK;
        config.curves = defaultBondingCurves();
        config.bondingLpFee = DEFAULT_FEE;
        config.rehypeStartFee = DEFAULT_FEE;
        config.rehypeEndFee = DEFAULT_FEE;
        config.rehypeFeeDurationSeconds = 0;
        config.rehypeStartingTime = 0;
        config.feeRoutingMode = FeeRoutingMode.DirectBuyback;
        config.feeDistribution = defaultFeeDistribution();
        config.migratorFee = DEFAULT_FEE;
        config.migratorUseDynamicFee = false;
        config.migratorTickSpacing = DEFAULT_TICK_SPACING;
        config.migratorLockDuration = DEFAULT_MIGRATOR_LOCK_DURATION;
        config.migratorRehypeCustomFee = DEFAULT_FEE;
        config.proceedsRecipient = address(0);
        config.proceedsShare = 0;
        config.tokenURI = "";
        config.maxBalanceLimit = 0;
        config.balanceLimitEnd = 0;
        config.balanceLimitController = address(0);
        config.minGraduateProceeds = DEFAULT_MIN_GRADUATE_PROCEEDS;
        config.minBondingDuration = DEFAULT_MIN_BONDING_DURATION;
    }

    /**
     * @notice Default multicurve (ETH FDV bands, spacing 8).
     * @dev Shares: 35% / 35% / 20% / 10% tail. `farTick` aligns to end of curve 3.
     */
    function defaultBondingCurves() internal pure returns (Curve[] memory curves) {
        curves = new Curve[](4);
        curves[0] = Curve({ tickLower: -112_040, tickUpper: -101_040, numPositions: 12, shares: 0.35e18 });
        curves[1] = Curve({ tickLower: -103_560, tickUpper: -93_056, numPositions: 12, shares: 0.35e18 });
        curves[2] = Curve({ tickLower: -94_120, tickUpper: -86_128, numPositions: 10, shares: 0.20e18 });
        curves[3] = Curve({
            tickLower: -86_128,
            tickUpper: DEFAULT_TAIL_TICK_UPPER,
            numPositions: 1,
            shares: 0.10e18
        });
    }

    /**
     * @notice Default Rehype fee matrix → FeeRouter (`buybackDst`).
     * @dev Each source row must sum to `WAD`.
     */
    function defaultFeeDistribution() internal pure returns (FeeDistributionInfo memory) {
        return FeeDistributionInfo({
            assetFeesToAssetBuybackWad: 0,
            assetFeesToNumeraireBuybackWad: WAD,
            assetFeesToBeneficiaryWad: 0,
            assetFeesToLpWad: 0,
            numeraireFeesToAssetBuybackWad: 0,
            numeraireFeesToNumeraireBuybackWad: WAD,
            numeraireFeesToBeneficiaryWad: 0,
            numeraireFeesToLpWad: 0
        });
    }

    // -------------------------------------------------------------------------
    //  Encoders → Airlock.create blobs
    // -------------------------------------------------------------------------

    /// @notice `DopplerERC20V1Factory` tokenData (no vesting / no balance limit by default).
    function encodeTokenFactoryData(
        string memory name,
        string memory symbol,
        MarketLaunchConfig memory config
    ) internal pure returns (bytes memory) {
        return abi.encode(
            name,
            symbol,
            new VestingSchedule[](0),
            new address[](0),
            new uint256[](0),
            new uint256[](0),
            config.tokenURI,
            config.maxBalanceLimit,
            config.balanceLimitEnd,
            config.balanceLimitController,
            new address[](0)
        );
    }

    /// @notice Nested Rehype bonding-hook init calldata (`buybackDst` = per-player FeeRouter).
    function encodeRehypeBondingHookData(
        address feeRouter,
        address numeraire,
        MarketLaunchConfig memory config
    ) internal pure returns (bytes memory) {
        return abi.encode(
            RehypeBondingHookData({
                numeraire: numeraire,
                buybackDst: feeRouter,
                startFee: config.rehypeStartFee,
                endFee: config.rehypeEndFee,
                durationSeconds: config.rehypeFeeDurationSeconds,
                startingTime: config.rehypeStartingTime,
                feeRoutingMode: config.feeRoutingMode,
                feeDistributionInfo: config.feeDistribution
            })
        );
    }

    /// @notice Nested Rehype migrator-hook init calldata (static custom fee; same buyback path).
    function encodeRehypeMigratorHookData(
        address feeRouter,
        address numeraire,
        MarketLaunchConfig memory config
    ) internal pure returns (bytes memory) {
        return abi.encode(
            RehypeMigratorHookData({
                numeraire: numeraire,
                buybackDst: feeRouter,
                customFee: config.migratorRehypeCustomFee,
                feeRoutingMode: config.feeRoutingMode,
                feeDistributionInfo: config.feeDistribution
            })
        );
    }

    /**
     * @notice `poolInitializerData` for `DopplerHookInitializer`.
     * @dev Empty bonding beneficiaries → pool stays `Initialized` (Airlock.migrate path).
     */
    function encodePoolInitializerData(
        address feeRouter,
        address numeraire,
        address rehypeHookInitializer,
        MarketLaunchConfig memory config
    ) internal pure returns (bytes memory) {
        return abi.encode(
            config.bondingLpFee,
            config.tickSpacing,
            config.farTick,
            config.curves,
            new Beneficiary[](0),
            rehypeHookInitializer,
            encodeRehypeBondingHookData(feeRouter, numeraire, config),
            new bytes(0)
        );
    }

    /**
     * @notice `liquidityMigratorData` for `DopplerHookMigrator.initialize`.
     * @dev Beneficiaries: integrator 95% + airlockOwner 5%, sorted ascending.
     */
    function encodeLiquidityMigratorData(
        address feeRouter,
        DopplerModules memory modules,
        MarketLaunchConfig memory config
    ) internal pure returns (bytes memory) {
        return abi.encode(
            config.migratorFee,
            config.migratorUseDynamicFee,
            config.migratorTickSpacing,
            config.migratorLockDuration,
            _migratorBeneficiaries(modules.integrator, modules.airlockOwner),
            modules.rehypeHookMigrator,
            encodeRehypeMigratorHookData(feeRouter, modules.numeraire, config),
            config.proceedsRecipient,
            config.proceedsShare
        );
    }

    /**
     * @notice Full `CreateParams` ready for `Airlock.create`.
     * @dev Module interface fields are written via assembly to bridge remapping type identity.
     */
    function buildCreateParams(
        DopplerModules memory modules,
        MarketLaunchConfig memory config,
        string memory name,
        string memory symbol,
        address feeRouter,
        bytes32 salt
    ) internal pure returns (CreateParams memory params) {
        params.initialSupply = config.initialSupply;
        params.numTokensToSell = config.numTokensToSell;
        params.numeraire = modules.numeraire;
        params.tokenFactoryData = encodeTokenFactoryData(name, symbol, config);
        params.governanceFactoryData = new bytes(0);
        params.poolInitializerData =
            encodePoolInitializerData(feeRouter, modules.numeraire, modules.rehypeHookInitializer, config);
        params.liquidityMigratorData = encodeLiquidityMigratorData(feeRouter, modules, config);
        params.integrator = modules.integrator;
        params.salt = salt;

        address tokenFactory = modules.tokenFactory;
        address governanceFactory = modules.governanceFactory;
        address poolInitializer = modules.poolInitializer;
        address liquidityMigrator = modules.liquidityMigrator;

        assembly ("memory-safe") {
            mstore(add(params, 0x60), tokenFactory)
            mstore(add(params, 0xa0), governanceFactory)
            mstore(add(params, 0xe0), poolInitializer)
            mstore(add(params, 0x120), liquidityMigrator)
        }
    }

    // -------------------------------------------------------------------------
    //  Internal
    // -------------------------------------------------------------------------

    function _migratorBeneficiaries(address integrator, address airlockOwner)
        private
        pure
        returns (Beneficiary[] memory beneficiaries)
    {
        uint96 ownerShares = PROTOCOL_OWNER_SHARES;
        uint96 integratorShares = uint96(WAD - uint256(ownerShares));

        beneficiaries = new Beneficiary[](2);
        if (integrator < airlockOwner) {
            beneficiaries[0] = Beneficiary({ beneficiary: integrator, shares: integratorShares });
            beneficiaries[1] = Beneficiary({ beneficiary: airlockOwner, shares: ownerShares });
        } else {
            beneficiaries[0] = Beneficiary({ beneficiary: airlockOwner, shares: ownerShares });
            beneficiaries[1] = Beneficiary({ beneficiary: integrator, shares: integratorShares });
        }
    }
}
