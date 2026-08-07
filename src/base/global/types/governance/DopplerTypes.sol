// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CreateParams } from "@doppler/src/Airlock.sol";
import {
    FeeDistributionInfo,
    FeeRoutingMode,
    InitData as RehypeBondingHookData,
    MigratorInitData as RehypeMigratorHookData
} from "@doppler/src/types/RehypeTypes.sol";
import { WAD } from "@doppler/src/types/Wad.sol";

/**
 * @title DopplerTypes
 * @notice Shared types + encoders for `Airlock.create` (Rehype multicurve path).
 * @dev Mutable launch parameters live on `DopplerConfig` (governance-updatable). This library
 *      holds ABI shapes, default constants, and pure encoders. `DopplerConfig.buildCreateParams`
 *      inlines these encoders so `DopplerLocker` stays under EIP-170.
 *
 *      Waiting-room cohort shapes used to live in `EligibilityTypes` (archived under
 *      `.junk/data-legacy`). Kept here so `DopplerLocker` stays compilable during the
 *      Phala data-plane redesign.
 */

/// @notice Eligibility cohort a candidate falls into (waiting-room tag).
enum EligibilityBucket {
    None,
    Goalkeeper,
    Under21,
    Outfield,
    NewTransfer
}

/// @notice Deploy / lifecycle cohorts from the legacy EligibilityVerifier classify pass.
/// @dev DopplerLocker intake is `queueAssets(leagueId, seasonId, playerIds)`; these groups remain for
///      the verifier return type until eligibility-2 flattens intake.
struct EligibilityGroups {
    bytes32[] goalkeepers;
    bytes32[] under21;
    bytes32[] outfield;
    bytes32[] newTransfers;
    bytes32[] toDeactivate;
    bytes32[] toReactivate;
}

/**
 * @dev Airlock / Rehype encoders follow.
 *
 *      Default economic recipe (ETH FDV, asset-as-token0 tick orientation):
 *        - Supply: 22M total / 20M to sell
 *        - Fee: 1% (`10_000` millionths)
 *        - Spacing: 8
 *        - Open mark: ~250 ETH FDV ≈ **$500k** at $2000/ETH (first curve start)
 *        - Graduate (`farTick`): ~2500 ETH FDV ≈ **$5M** at $2000/ETH (price gate only)
 *        - Curves (Doppler-shaped 30/40/20/10, market-cap bands → ticks):
 *            30%  $500k → $1.5M  (250 → 750 ETH)   (−113856 → −102872)
 *            40%  $1.0M → $4.0M  (500 → 2000 ETH)  (−106928 → −93064)
 *            20%  $3.5M → $5.0M  (1750 → 2500 ETH) (−94392 → −90832)
 *            10%  $5.0M → max    (2500 ETH → max)  (−90832 → 887272) tail
 *        - `farTick` = −90832. Sole `DopplerHookInitializer` migrate gate.
 *        - Est. raise on a clean walk: ~$2.0–2.3M (~1000–1150 ETH); ~2M tokens remain for spot.
 *        - `minGraduateProceeds` / `minBondingDuration` unused by Airlock/HookInitializer
 *          (reserved HP policy storage only).
 *
 *      Fee matrix → FeeRouter (`buybackDst`):
 *        - ETH fees: direct (`numeraireFeesToNumeraireBuybackWad`)
 *        - Player-token fees: swap to ETH (`assetFeesToNumeraireBuybackWad`)
 *        - Rehype: 5% of swap fee → Airlock owner; remaining 95% → FeeRouter
 *        - FeeRouter (one per market; `status` cache via `PlayerSetRegistry.setStatus`):
 *            BONDING: 10/95 integrator → gross 5:10:85 (Doppler : HP : redistrib)
 *            GRADUATED / INACTIVE: 5/95 → gross 5:5:90
 *        - Spot pool LP fee default 0.15% (`migratorFee`) → StreamableFeesLocker 5:95
 *          (Doppler airlock : HP / `HP_TREASURY`); Rehype trading fee stays 1%
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

    /// @dev ~2500 ETH FDV ≈ $5M at $2000/ETH (end of main discovery / start of tail).
    int24 internal constant DEFAULT_FAR_TICK = -90_832;

    /// @dev Uniswap V4 max tick (aligned to spacing 8).
    int24 internal constant DEFAULT_TAIL_TICK_UPPER = 887_272;

    /// @dev 1% in Uniswap V4 millionths (Rehype trading fee — bonding + spot).
    uint24 internal constant DEFAULT_FEE = 10_000;

    /// @dev 0.15% pool LP fee post-migrate → StreamableFeesLocker 5:95.
    uint24 internal constant DEFAULT_MIGRATOR_LP_FEE = 1500;

    uint32 internal constant DEFAULT_MIGRATOR_LOCK_DURATION = 30 days;

    /// @dev Reserved HP soft-graduate storage (not enforced by Airlock / HookInitializer).
    uint256 internal constant DEFAULT_MIN_GRADUATE_PROCEEDS = 50 ether;

    /// @dev Reserved HP soft-graduate storage (not enforced by Airlock / HookInitializer).
    uint32 internal constant DEFAULT_MIN_BONDING_DURATION = 30 days;

    /// @dev DN404 unit: 1000 whole tokens → 1 NFT (matches Doppler DN404 factory tests).
    uint256 internal constant DEFAULT_DN404_UNIT = 1000 ether;

    /// @dev Doppler `MIN_PROTOCOL_OWNER_SHARES` = WAD / 20 (5%) — StreamableFeesLocker.
    uint96 internal constant PROTOCOL_OWNER_SHARES = uint96(WAD / 20);

    /// @dev HP (`HP_TREASURY`) StreamableFeesLocker share (95%).
    uint96 internal constant HP_LP_SHARES = uint96(WAD - uint256(PROTOCOL_OWNER_SHARES));

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

    // -------------------------------------------------------------------------
    //  Module wiring + shared launch config
    // -------------------------------------------------------------------------

    /**
     * @notice Whitelisted Doppler / HP module addresses used when building `CreateParams`.
     * @dev Resolved on `DopplerLocker` from AddressProvider (owner may override modules).
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
        /// @dev Airlock integrator fee recipient (`CreateParams.integrator`).
        address integrator;
        address airlockOwner;
        /// @dev Launchpad “timelock” / excess supply recipient (`governanceFactoryData`).
        address stakeVesting;
        /// @dev StreamableFeesLocker beneficiary (95% of post-migrate LP fees) — `HP_TREASURY`.
        address hpTreasury;
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
        /// @dev Optional legacy HTTPS prefix. Live launches set per-token `baseURI` via oracle
        ///      IPFS pin at `CvmJob.FinalConfig`; this field is not used for CREATE2.
        string baseURI;
        /// @dev DN404 fungible→NFT unit; must be non-zero and divide `initialSupply`.
        uint256 dn404Unit;
        uint256 minGraduateProceeds;
        uint32 minBondingDuration;
    }

    /**
     * @notice One waiting-room candidate (cohort + optional StatsPerform name/symbol).
     * @dev `metadataSet` true when copied from EligibilityVerifier (CRE) or set manually.
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

    /// @notice Recommended launch config (~$500k–$5M FDV @ $2000/ETH, 1% fee, 4-curve).
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
        config.migratorFee = DEFAULT_MIGRATOR_LP_FEE;
        config.migratorUseDynamicFee = false;
        config.migratorTickSpacing = DEFAULT_TICK_SPACING;
        config.migratorLockDuration = DEFAULT_MIGRATOR_LOCK_DURATION;
        config.migratorRehypeCustomFee = DEFAULT_FEE;
        config.proceedsRecipient = address(0);
        config.proceedsShare = 0;
        config.baseURI = "";
        config.dn404Unit = DEFAULT_DN404_UNIT;
        config.minGraduateProceeds = DEFAULT_MIN_GRADUATE_PROCEEDS;
        config.minBondingDuration = DEFAULT_MIN_BONDING_DURATION;
    }

    /**
     * @notice Default multicurve (ETH FDV bands, spacing 8).
     * @dev Shares: 30% / 40% / 20% / 10% tail. `farTick` = end of curve 3 (~2500 ETH / $5M FDV).
     */
    function defaultBondingCurves() internal pure returns (Curve[] memory curves) {
        curves = new Curve[](4);
        curves[0] = Curve({ tickLower: -113_856, tickUpper: -102_872, numPositions: 10, shares: 0.3e18 });
        curves[1] = Curve({ tickLower: -106_928, tickUpper: -93_064, numPositions: 15, shares: 0.4e18 });
        curves[2] = Curve({ tickLower: -94_392, tickUpper: -90_832, numPositions: 10, shares: 0.2e18 });
        curves[3] = Curve({ tickLower: -90_832, tickUpper: DEFAULT_TAIL_TICK_UPPER, numPositions: 1, shares: 0.1e18 });
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

    /// @notice Per-player DN404 metadata prefix: `globalPrefix + 0x{playerId hex}/`.
    function playerBaseURI(string memory globalPrefix, bytes32 playerId) internal pure returns (string memory) {
        return string.concat(globalPrefix, bytes32ToHex(playerId), "/");
    }

    /// @dev Lowercase `0x` + 64 hex chars for URL path segments.
    function bytes32ToHex(bytes32 value) internal pure returns (string memory) {
        bytes16 symbols = "0123456789abcdef";
        bytes memory str = new bytes(66);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i; i < 32; ++i) {
            uint8 b = uint8(value[i]);
            str[2 + i * 2] = symbols[b >> 4];
            str[3 + i * 2] = symbols[b & 0x0f];
        }
        return string(str);
    }

    /// @notice `DN404Factory` tokenData: `(name, symbol, baseURI, unit)`.
    /// @param baseURI_ Per-player metadata prefix (`…/metadata/0x{playerId}/`).
    function encodeTokenFactoryData(
        string memory name,
        string memory symbol,
        string memory baseURI_,
        MarketLaunchConfig memory config
    ) internal pure returns (bytes memory) {
        return abi.encode(name, symbol, baseURI_, config.dn404Unit);
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
     * @dev Beneficiaries (StreamableFeesLocker): 5% airlockOwner / 95% HP (`hpTreasury`).
     *      Bonding initializer beneficiaries stay empty (preserve `Airlock.migrate`).
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
            _migratorBeneficiaries(modules.airlockOwner, modules.hpTreasury),
            modules.rehypeHookMigrator,
            encodeRehypeMigratorHookData(feeRouter, modules.numeraire, config),
            config.proceedsRecipient,
            config.proceedsShare
        );
    }

    /**
     * @notice Full `CreateParams` ready for `Airlock.create`.
     * @dev Module interface fields are written via assembly to bridge remapping type identity.
     *      `governanceFactoryData` = Launchpad excess recipient (`StakeVesting`).
     */
    function buildCreateParams(
        DopplerModules memory modules,
        MarketLaunchConfig memory config,
        string memory name,
        string memory symbol,
        string memory baseURI_,
        address feeRouter,
        bytes32 salt
    ) internal pure returns (CreateParams memory params) {
        params.initialSupply = config.initialSupply;
        params.numTokensToSell = config.numTokensToSell;
        params.numeraire = modules.numeraire;
        params.tokenFactoryData = encodeTokenFactoryData(name, symbol, baseURI_, config);
        params.governanceFactoryData = abi.encode(modules.stakeVesting);
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

    /// @dev 5% airlock owner / 95% HP treasury — addresses sorted ascending.
    function _migratorBeneficiaries(
        address airlockOwner,
        address hpTreasury
    ) private pure returns (Beneficiary[] memory beneficiaries) {
        beneficiaries = new Beneficiary[](2);
        if (airlockOwner < hpTreasury) {
            beneficiaries[0] = Beneficiary({ beneficiary: airlockOwner, shares: PROTOCOL_OWNER_SHARES });
            beneficiaries[1] = Beneficiary({ beneficiary: hpTreasury, shares: HP_LP_SHARES });
        } else {
            beneficiaries[0] = Beneficiary({ beneficiary: hpTreasury, shares: HP_LP_SHARES });
            beneficiaries[1] = Beneficiary({ beneficiary: airlockOwner, shares: PROTOCOL_OWNER_SHARES });
        }
    }
}
