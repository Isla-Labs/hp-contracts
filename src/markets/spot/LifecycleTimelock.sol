// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import {
    AdvancedTradeData,
    AssetData,
    DN404CreateParams,
    MarketStatus,
    PlayerVaultData,
    RegistryData,
    SpotMarketData
} from "@base/global/types/AssetTypes.sol";
import { AssetRegistry } from "../../AssetRegistry.sol";
import { IAdvancedTradeVault } from "../advanced-updated/interfaces/IAdvancedTradeVault.sol";
import { IAdvancedTradeVaultFactory } from "../advanced-updated/interfaces/IAdvancedTradeVaultFactory.sol";
import { IFundingController } from "../advanced-updated/interfaces/IFundingController.sol";
import { PoolMarkSource } from "../advanced-updated/oracles/PoolMarkSource.sol";
import { SEEDED_INVENTORY } from "../advanced-updated/types/AdvancedTradeTypes.sol";
import { IPlayerVault } from "../../vaults/interfaces/IPlayerVault.sol";
import { IPlayerVaultFactory } from "../../vaults/interfaces/IPlayerVaultFactory.sol";
import { FeeRouter } from "./FeeRouter.sol";
import { FeeRouterFactory } from "./FeeRouterFactory.sol";

/**
 * @title LifecycleTimelock
 * @notice Queues and executes market deployments and PBRTreasury transfer updates with a fixed delay.
 * @dev Trustless backend verification will be added later. Until then, only the owner may enqueue.
 *
 *      Remains the Ownable owner of each FeeRouter so `setPbrTreasury` can be executed from
 *      `transferQueue` after the waiting period.
 *
 *      Deploy order: LifecycleTimelock → FeeRouterFactory(this) → setFeeRouterFactory
 *      → AdvancedTradeVaultFactory(this) → setAdvancedTradeVaultFactory → set collateral /
 *      poolManager / assetRegistry / swapRouter / impactEstimator → setAirlock.
 *
 *      Per-market execute path: Doppler → FeeRouter → PoolMarkSource → AdvancedTradeVault
 *      (1M seed) → PlayerVault → vault wiring → FundingController.registerMarket → AssetRegistry.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract LifecycleTimelock is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --------------------------------------------
    //  Constants
    // --------------------------------------------

    /// @notice Waiting period enforced for deployment and transfer queues
    uint256 public constant QUEUE_DELAY = 1 days;

    // --------------------------------------------
    //  Config
    // --------------------------------------------

    /// @notice Factory that deploys per-market FeeRouters owned by this timelock
    FeeRouterFactory public feeRouterFactory;

    /// @notice Platform FundingController / FRT — FeeRouter `atFunding` + vault fundingController
    address public immutable atFunding;

    /// @notice PlayerVaultFactory — wire once implemented
    address public playerVaultFactory;

    /// @notice AdvancedTradeVaultFactory (beacon owner = this timelock)
    IAdvancedTradeVaultFactory public advancedTradeVaultFactory;

    /// @notice Doppler Airlock — wire once CreateParams encoding is finalized
    address public airlock;

    /// @notice AssetRegistry for pool keys + AdvancedTrade discovery
    AssetRegistry public assetRegistry;

    /// @notice Uniswap V4 PoolManager (PoolMarkSource)
    IPoolManager public poolManager;

    /// @notice USDC (or launch collateral) for AdvancedTradeVault
    address public collateral;

    /// @notice Shared IVaultSwapRouter for AdvancedTradeVault
    address public swapRouter;

    /// @notice Shared PoolImpactEstimator (optional; address(0) skips wiring)
    address public impactEstimator;

    // --------------------------------------------
    //  Queue types
    // --------------------------------------------

    struct DeploymentRequest {
        DN404CreateParams metadata;
        address pbrTreasury;
        uint256 eta;
        bool exists;
        bool executed;
        bool cancelled;
    }

    struct TransferRequest {
        address feeRouter;
        address playerToken;
        address newPbrTreasury;
        uint256 eta;
        bool exists;
        bool executed;
        bool cancelled;
    }

    /// @notice Canonized deployment requests keyed by request id
    mapping(bytes32 requestId => DeploymentRequest request) public deploymentQueue;

    /// @notice Canonized transfer requests keyed by request id
    mapping(bytes32 requestId => TransferRequest request) public transferQueue;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    event DeploymentQueued(
        bytes32 indexed requestId,
        bytes32 indexed playerId,
        bytes32 indexed leagueId,
        string name,
        string symbol,
        bytes32 salt,
        address pbrTreasury,
        uint256 eta
    );
    event DeploymentExecuted(
        bytes32 indexed requestId,
        address indexed market,
        address feeRouter,
        address playerVault,
        address advancedTradeVault,
        address markSource
    );
    event DeploymentCancelled(bytes32 indexed requestId);

    event TransferQueued(
        bytes32 indexed requestId,
        address indexed feeRouter,
        address indexed market,
        address newPbrTreasury,
        uint256 eta
    );
    event TransferExecuted(bytes32 indexed requestId, address indexed feeRouter, address newPbrTreasury);
    event TransferCancelled(bytes32 indexed requestId);

    event FeeRouterFactoryUpdated(address indexed factory);
    event PlayerVaultFactoryUpdated(address indexed factory);
    event AdvancedTradeVaultFactoryUpdated(address indexed factory);
    event AirlockUpdated(address indexed airlock);
    event AssetRegistryUpdated(address indexed registry);
    event PoolManagerUpdated(address indexed poolManager);
    event CollateralUpdated(address indexed collateral);
    event SwapRouterUpdated(address indexed swapRouter);
    event ImpactEstimatorUpdated(address indexed impactEstimator);

    error ZeroAddress();
    error AlreadyQueued();
    error UnknownRequest();
    error AlreadyExecuted();
    error AlreadyCancelled();
    error DelayNotElapsed(uint256 eta, uint256 currentTimestamp);
    error FactoryNotConfigured();
    error InsufficientSeedInventory(uint256 have, uint256 need);

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /**
     * @param initialOwner Admin that may queue/cancel requests (platform ops until trustless path lands).
     * @param atFunding_ FundingController / FRT forwarded into each FeeRouter and AdvancedTradeVault.
     */
    constructor(address initialOwner, address atFunding_) Ownable(initialOwner) {
        if (atFunding_ == address(0)) revert ZeroAddress();
        atFunding = atFunding_;
    }

    // --------------------------------------------
    //  Factory / dependency wiring
    // --------------------------------------------

    function setFeeRouterFactory(address factory) external onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        feeRouterFactory = FeeRouterFactory(factory);
        emit FeeRouterFactoryUpdated(factory);
    }

    function setPlayerVaultFactory(address factory) external onlyOwner {
        playerVaultFactory = factory;
        emit PlayerVaultFactoryUpdated(factory);
    }

    function setAdvancedTradeVaultFactory(address factory) external onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        advancedTradeVaultFactory = IAdvancedTradeVaultFactory(factory);
        emit AdvancedTradeVaultFactoryUpdated(factory);
    }

    function setAirlock(address airlock_) external onlyOwner {
        airlock = airlock_;
        emit AirlockUpdated(airlock_);
    }

    function setAssetRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        assetRegistry = AssetRegistry(registry);
        emit AssetRegistryUpdated(registry);
    }

    function setPoolManager(address poolManager_) external onlyOwner {
        if (poolManager_ == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(poolManager_);
        emit PoolManagerUpdated(poolManager_);
    }

    function setCollateral(address collateral_) external onlyOwner {
        if (collateral_ == address(0)) revert ZeroAddress();
        collateral = collateral_;
        emit CollateralUpdated(collateral_);
    }

    function setSwapRouter(address swapRouter_) external onlyOwner {
        swapRouter = swapRouter_;
        emit SwapRouterUpdated(swapRouter_);
    }

    function setImpactEstimator(address impactEstimator_) external onlyOwner {
        impactEstimator = impactEstimator_;
        emit ImpactEstimatorUpdated(impactEstimator_);
    }

    // --------------------------------------------
    //  Deployment queue
    // --------------------------------------------

    /**
     * @notice Canonizes Doppler/market metadata onchain and starts the deployment waiting period.
     * @dev Trustless verification of backend metadata will be added later.
     * @return requestId Idempotent id derived from the canonized metadata + treasury.
     */
    function queueDeployment(DN404CreateParams calldata metadata, address pbrTreasury)
        external
        onlyOwner
        returns (bytes32 requestId)
    {
        if (pbrTreasury == address(0)) revert ZeroAddress();
        if (metadata.playerId == bytes32(0) || metadata.leagueId == bytes32(0) || metadata.salt == bytes32(0)) {
            revert ZeroAddress();
        }

        requestId = _deploymentId(metadata, pbrTreasury);
        DeploymentRequest storage request = deploymentQueue[requestId];
        if (request.exists) revert AlreadyQueued();

        uint256 eta = block.timestamp + QUEUE_DELAY;
        deploymentQueue[requestId] = DeploymentRequest({
            metadata: metadata,
            pbrTreasury: pbrTreasury,
            eta: eta,
            exists: true,
            executed: false,
            cancelled: false
        });

        emit DeploymentQueued(
            requestId,
            metadata.playerId,
            metadata.leagueId,
            metadata.name,
            metadata.symbol,
            metadata.salt,
            pbrTreasury,
            eta
        );
    }

    /**
     * @notice Executes a ready deployment: Doppler → FeeRouter → PoolMarkSource → AdvancedTradeVault
     *         → PlayerVault → FundingController registration → AssetRegistry.
     * @dev This timelock must hold `SEEDED_INVENTORY` (1M) of the new player token before
     *      AdvancedTradeVaultFactory.create pulls the short-side seed (20:1:1 allocation).
     */
    function executeDeployment(bytes32 requestId)
        external
        nonReentrant
        returns (
            address market,
            address feeRouter,
            address playerVault,
            address advancedTradeVault,
            address markSource
        )
    {
        DeploymentRequest storage request = deploymentQueue[requestId];
        _requireExecutable(request.exists, request.executed, request.cancelled, request.eta);
        _requireDeployDeps();

        request.executed = true;

        DN404CreateParams memory metadata = request.metadata;
        address pbrTreasury = request.pbrTreasury;
        PoolKey memory activePool;

        // --------------------------------------------------
        // 1) Doppler (Airlock.create) — returns market + pool
        // --------------------------------------------------
        // `metadata` is the canonized DN404 / market identity portion of CreateParams.
        // Full Airlock CreateParams (initializer, migrator data with buybackDst = feeRouter
        // predicted via CREATE2, governance factory, numeraire, etc.) will be assembled here
        // once Doppler wiring is finalized. Prefer CREATE2-predict FeeRouter so buybackDst
        // can be set at migrate time; otherwise attach FeeRouter via setDopplerHook after.
        //
        // (market, …, activePool) = IAirlock(airlock).create(CreateParams({ … salt: metadata.salt … }));
        metadata; // held in deploymentQueue until Airlock create is wired
        activePool; // assigned from Doppler create result

        if (market == address(0)) revert FactoryNotConfigured();

        // --------------------------------------------------
        // 2–7) Post-Doppler stack
        // --------------------------------------------------
        (feeRouter, playerVault, advancedTradeVault, markSource) =
            _deployMarketStack(market, activePool, pbrTreasury, metadata);

        emit DeploymentExecuted(requestId, market, feeRouter, playerVault, advancedTradeVault, markSource);
    }

    /**
     * @dev FeeRouter → PoolMarkSource → AdvancedTradeVault (seeded) → PlayerVault → wire →
     *      FundingController.registerMarket → AssetRegistry.createAsset.
     */
    function _deployMarketStack(
        address market,
        PoolKey memory activePool,
        address pbrTreasury,
        DN404CreateParams memory metadata
    )
        internal
        returns (address feeRouter, address playerVault, address advancedTradeVault, address markSource)
    {
        // 2) FeeRouter — this timelock remains owner for transferQueue / setPbrTreasury
        feeRouter = feeRouterFactory.create(market, atFunding, pbrTreasury);

        // 3) Per-market mark reader (registry pool key must be written before first spot read)
        markSource = address(new PoolMarkSource(assetRegistry, poolManager, market));

        // 4) AdvancedTradeVault — pull 1M short inventory from this timelock
        uint256 seed = SEEDED_INVENTORY;
        uint256 bal = IERC20(market).balanceOf(address(this));
        if (bal < seed) revert InsufficientSeedInventory(bal, seed);

        IERC20(market).forceApprove(address(advancedTradeVaultFactory), seed);
        advancedTradeVault = advancedTradeVaultFactory.create(
            market,
            collateral,
            swapRouter,
            markSource,
            atFunding, // FundingController
            pbrTreasury,
            seed
        );
        IERC20(market).forceApprove(address(advancedTradeVaultFactory), 0);

        if (impactEstimator != address(0)) {
            IAdvancedTradeVault(advancedTradeVault).setImpactEstimator(impactEstimator);
        }

        // 5) PlayerVault — bidirectional exclusivity wiring
        if (playerVaultFactory != address(0)) {
            playerVault = IPlayerVaultFactory(playerVaultFactory).create(market);
            IAdvancedTradeVault(advancedTradeVault).setPlayerVault(playerVault);
            IPlayerVault(playerVault).setAdvancedTradeVault(advancedTradeVault);
        }

        // 6) FundingController — register for Phase 2 checkpoints (grace until setGrace(false))
        IFundingController(payable(atFunding)).registerMarket(advancedTradeVault, market);

        // 7) AssetRegistry — canonize market discovery (pool key from Doppler)
        assetRegistry.createAsset(
            market,
            AssetData({
                playerId: metadata.playerId,
                leagueId: metadata.leagueId,
                token: market,
                symbol: metadata.symbol,
                registryData: RegistryData({
                    spotMarketData: SpotMarketData({
                        activePool: activePool,
                        hookDoppler: address(0),
                        hookMigrator: address(0),
                        feeRouter: feeRouter
                    }),
                    advancedTradeData: AdvancedTradeData({
                        advancedTradeVault: advancedTradeVault,
                        markSource: markSource
                    }),
                    playerVaultData: PlayerVaultData({
                        playerVault: playerVault,
                        stToken: playerVault == address(0) ? address(0) : IPlayerVault(playerVault).stToken(),
                        isUtilized: playerVault != address(0)
                    }),
                    deployedAt: block.timestamp,
                    graduatedAt: 0,
                    deactivatedAt: 0
                }),
                marketStatus: MarketStatus.BONDING
            })
        );
    }

    function cancelDeployment(bytes32 requestId) external onlyOwner {
        DeploymentRequest storage request = deploymentQueue[requestId];
        if (!request.exists) revert UnknownRequest();
        if (request.executed) revert AlreadyExecuted();
        if (request.cancelled) revert AlreadyCancelled();

        request.cancelled = true;
        emit DeploymentCancelled(requestId);
    }

    // --------------------------------------------
    //  Transfer queue (PBRTreasury updates)
    // --------------------------------------------

    /**
     * @notice Queues a FeeRouter PBRTreasury update. Executable after `QUEUE_DELAY`.
     * @param feeRouter FeeRouter owned by this timelock.
     * @param newPbrTreasury Destination treasury after the transfer waiting period.
     */
    function queueTransfer(address feeRouter, address newPbrTreasury) external onlyOwner returns (bytes32 requestId) {
        if (feeRouter == address(0) || newPbrTreasury == address(0)) revert ZeroAddress();

        address playerToken = FeeRouter(payable(feeRouter)).playerToken();
        requestId = _transferId(feeRouter, newPbrTreasury);
        TransferRequest storage request = transferQueue[requestId];
        if (request.exists) revert AlreadyQueued();

        uint256 eta = block.timestamp + QUEUE_DELAY;
        transferQueue[requestId] = TransferRequest({
            feeRouter: feeRouter,
            playerToken: playerToken,
            newPbrTreasury: newPbrTreasury,
            eta: eta,
            exists: true,
            executed: false,
            cancelled: false
        });

        emit TransferQueued(requestId, feeRouter, playerToken, newPbrTreasury, eta);
    }

    /**
     * @notice Applies a ready PBRTreasury update on the FeeRouter (timelock is FeeRouter owner).
     */
    function executeTransfer(bytes32 requestId) external nonReentrant {
        TransferRequest storage request = transferQueue[requestId];
        _requireExecutable(request.exists, request.executed, request.cancelled, request.eta);

        request.executed = true;
        FeeRouter(payable(request.feeRouter)).setPbrTreasury(request.newPbrTreasury);

        emit TransferExecuted(requestId, request.feeRouter, request.newPbrTreasury);
    }

    function cancelTransfer(bytes32 requestId) external onlyOwner {
        TransferRequest storage request = transferQueue[requestId];
        if (!request.exists) revert UnknownRequest();
        if (request.executed) revert AlreadyExecuted();
        if (request.cancelled) revert AlreadyCancelled();

        request.cancelled = true;
        emit TransferCancelled(requestId);
    }

    // --------------------------------------------
    //  Views / helpers
    // --------------------------------------------

    function _requireDeployDeps() internal view {
        if (address(feeRouterFactory) == address(0)) revert FactoryNotConfigured();
        if (airlock == address(0)) revert FactoryNotConfigured();
        if (address(advancedTradeVaultFactory) == address(0)) revert FactoryNotConfigured();
        if (address(assetRegistry) == address(0)) revert FactoryNotConfigured();
        if (address(poolManager) == address(0)) revert FactoryNotConfigured();
        if (collateral == address(0)) revert FactoryNotConfigured();
    }

    function _deploymentId(DN404CreateParams calldata metadata, address pbrTreasury)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                metadata.playerId, metadata.leagueId, metadata.name, metadata.symbol, metadata.salt, pbrTreasury
            )
        );
    }

    function _transferId(address feeRouter, address newPbrTreasury) internal pure returns (bytes32) {
        return keccak256(abi.encode(feeRouter, newPbrTreasury));
    }

    function _requireExecutable(bool exists, bool executed, bool cancelled, uint256 eta) internal view {
        if (!exists) revert UnknownRequest();
        if (executed) revert AlreadyExecuted();
        if (cancelled) revert AlreadyCancelled();
        if (block.timestamp < eta) revert DelayNotElapsed(eta, block.timestamp);
    }
}
