// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";

import { DN404CreateParams } from "../../base/global/types/AssetTypes.sol";
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
 *      Deploy order: LifecycleTimelock → FeeRouterFactory(this) → setFeeRouterFactory.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract LifecycleTimelock is Ownable2Step, ReentrancyGuard {
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

    /// @notice Platform FRTreasury passed through to each FeeRouter
    address public immutable atFunding;

    /// @notice PlayerVaultFactory — wire once implemented
    address public playerVaultFactory;

    /// @notice AdvancedTradeVaultFactory — wire once implemented
    address public advancedTradeVaultFactory;

    /// @notice Doppler Airlock — wire once CreateParams encoding is finalized
    address public airlock;

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
        address advancedTradeVault
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

    error ZeroAddress();
    error AlreadyQueued();
    error UnknownRequest();
    error AlreadyExecuted();
    error AlreadyCancelled();
    error DelayNotElapsed(uint256 eta, uint256 currentTimestamp);
    error FactoryNotConfigured();

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /**
     * @param initialOwner Admin that may queue/cancel requests (platform ops until trustless path lands).
     * @param atFunding_ FRTreasury address forwarded into each FeeRouter.
     */
    constructor(address initialOwner, address atFunding_) Ownable(initialOwner) {
        if (atFunding_ == address(0)) revert ZeroAddress();
        atFunding = atFunding_;
    }

    // --------------------------------------------
    //  Factory wiring
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
        advancedTradeVaultFactory = factory;
        emit AdvancedTradeVaultFactoryUpdated(factory);
    }

    function setAirlock(address airlock_) external onlyOwner {
        airlock = airlock_;
        emit AirlockUpdated(airlock_);
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
     * @notice Executes a ready deployment: Doppler + AdvancedTradeVault + FeeRouter + PlayerVault.
     * @dev Incomplete factories are left as commented integration points. FeeRouter ownership stays
     *      with this timelock via FeeRouterFactory.
     */
    function executeDeployment(bytes32 requestId)
        external
        nonReentrant
        returns (address market, address feeRouter, address playerVault, address advancedTradeVault)
    {
        DeploymentRequest storage request = deploymentQueue[requestId];
        _requireExecutable(request.exists, request.executed, request.cancelled, request.eta);

        if (address(feeRouterFactory) == address(0)) revert FactoryNotConfigured();
        // Doppler Airlock is required before a real market address exists for downstream factories.
        if (airlock == address(0)) revert FactoryNotConfigured();

        request.executed = true;

        DN404CreateParams memory metadata = request.metadata;
        address pbrTreasury = request.pbrTreasury;

        // --------------------------------------------------
        // 1) Doppler (Airlock.create)
        // --------------------------------------------------
        // `metadata` is the canonized DN404 / market identity portion of CreateParams
        // (playerId, leagueId, name, symbol, salt). Full Airlock CreateParams — initializer,
        // migrator data with buybackDst = feeRouter, governance factory, numeraire, etc. —
        // will be assembled here once Doppler wiring is finalized.
        //
        // (market,,,,,,) = IAirlock(airlock).create(
        //     CreateParams({
        //         /* tokenFactoryData encodes metadata.name / symbol / salt / ... */
        //         salt: metadata.salt,
        //         ...
        //     })
        // );
        metadata; // canonized onchain via deploymentQueue; used when Airlock create is wired

        // --------------------------------------------------
        // 2) AdvancedTradeVault
        // --------------------------------------------------
        // if (advancedTradeVaultFactory == address(0)) revert FactoryNotConfigured();
        // advancedTradeVault = IAdvancedTradeVaultFactory(advancedTradeVaultFactory).create(market);

        // --------------------------------------------------
        // 3) FeeRouter — this timelock remains owner for transferQueue / setPbrTreasury
        // --------------------------------------------------
        // feeRouter = feeRouterFactory.create(market, atFunding, pbrTreasury);

        // --------------------------------------------------
        // 4) PlayerVault
        // --------------------------------------------------
        // if (playerVaultFactory == address(0)) revert FactoryNotConfigured();
        // playerVault = IPlayerVaultFactory(playerVaultFactory).create(market);

        // --------------------------------------------------
        // 5) AssetRegistry.createAsset(...) — wire once registry auth is defined
        // --------------------------------------------------

        if (market == address(0)) revert FactoryNotConfigured();

        // Unreachable until Doppler create assigns `market`; keeps the intended call order explicit.
        feeRouter = feeRouterFactory.create(market, atFunding, pbrTreasury);
        pbrTreasury;

        emit DeploymentExecuted(requestId, market, feeRouter, playerVault, advancedTradeVault);
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
