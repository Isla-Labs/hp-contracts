// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { Oracle } from "@base/abstract/Oracle.sol";
import { RateLimit } from "@base/abstract/RateLimit.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { MineSalt } from "@base/global/libraries/MineSalt.sol";
import { DeploymentsErrors as Errors } from "@errors/governance/DeploymentsErrors.sol";
import { DeploymentsEvents as Events } from "@events/governance/DeploymentsEvents.sol";
import { IDopplerLocker } from "@interfaces/governance/IDopplerLocker.sol";
import { IOrchestrator } from "@interfaces/IOrchestrator.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { DopplerTypes } from "@types/governance/DopplerTypes.sol";
import { CvmJob, VanityDeployKind } from "@types/oracle/CvmTypes.sol";
import { DopplerData, TokenData, TournamentData, VaultData } from "@types/PlayerSetTypes.sol";
import { AddressProvider } from "@src/AddressProvider.sol";
import { FeeRouterFactory } from "@markets/factories/FeeRouterFactory.sol";
import { PlayerVaultFactory } from "@vaults/factories/PlayerVaultFactory.sol";

import { Airlock, CreateParams } from "@doppler/src/Airlock.sol";
import { DopplerHookInitializer } from "@doppler/src/initializers/DopplerHookInitializer.sol";
import { FeeDistributionInfo } from "@doppler/src/types/RehypeTypes.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { DopplerConfig } from "@deployments/assets/deploy/config/DopplerConfig.sol";

/**
 * @title DopplerLocker
 * @notice Intake → metadata → explicit 24h queue → vanity salts → deploy handoff.
 * @dev Dual CVM jobs via `Oracle._sendOracleRequest(job, args)`:
 *        1) `queueAssets` → `CvmJob.PlayerMetadata` (`seasonId`, `playerIds[]`)
 *        2) `deployAssets` (rate-limited) → `CvmJob.VanitySalts` (Asset) once wait elapsed
 *
 *      Flow:
 *        owner `queueAssets(seasonId, playerIds)` → `AwaitingMetadata` + metadata request
 *        → fulfill → `ReadyToQueue` (name/symbol set; clock not started)
 *        → next `queueAssets` promotes `ReadyToQueue` → `Queued` (`queuedAt = now`)
 *        → owner may `editMetadata` / `unqueueAsset` during the 24h window
 *        → anyone calls `deployAssets` after wait; RateLimit gates frequency
 *        → VanitySalts fulfill → `_onDeployReady` (FeeRouter → Airlock → Vault → registry)
 *
 *      Factory / registry writes relay through `Orchestrator.execute` (this proxy must hold
 *      `AUTHORIZED_CONTRACT`). `Airlock.create` is called directly.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract DopplerLocker is Initializable, AddressBook, Ownable, DopplerConfig, Oracle, RateLimit, IDopplerLocker {
    // -------------------------------------------------------------------------
    //  Types
    // -------------------------------------------------------------------------

    enum QueueStatus {
        None,
        /// @dev Intake; waiting on PlayerMetadata.
        AwaitingMetadata,
        /// @dev Metadata set; waiting for owner to start the 24h window via `queueAssets`.
        ReadyToQueue,
        /// @dev In the 24h review window (`queuedAt + queueWait`).
        Queued,
        /// @dev VanitySalts request in flight.
        AwaitingSalts,
        /// @dev Salts stored; ready for Airlock / vault deploy.
        DeployReady,
        Deployed
    }

    enum OracleKind {
        None,
        PlayerMetadata,
        VanitySalts
    }

    struct QueueEntry {
        bytes32 playerId;
        /// @dev Tournament-calendar HPID (`tmcl` after HPID decode).
        bytes32 seasonId;
        string name;
        string symbol;
        bool metadataSet;
        uint64 queuedAt;
        QueueStatus status;
        bytes32 tokenSalt;
        address tokenPredicted;
        bytes32 vaultSalt;
        address vaultPredicted;
    }

    // -------------------------------------------------------------------------
    //  Constants
    // -------------------------------------------------------------------------

    uint256 public constant DEFAULT_QUEUE_WAIT = 24 hours;
    uint256 public constant DEFAULT_DEPLOY_COOLDOWN = 5 minutes;
    /// @notice Max players per `queueAssets` call and per PlayerMetadata oracle page.
    uint256 public constant METADATA_BATCH_SIZE = 50;

    // -------------------------------------------------------------------------
    //  Immutables / config
    // -------------------------------------------------------------------------

    /// @notice Seconds after `Queued` before `deployAssets` may request vanity salts.
    uint256 public queueWait;

    /// @notice `DN404Factory` (CREATE2 deployer for PlayerToken).
    address public tokenFactory;

    /// @notice `PlayerVaultFactory` (CreateX CREATE3 deployer).
    address public vaultFactory;

    /// @notice Doppler Airlock — `recipient` / `owner` in DN404 ctor (initcode hash).
    address public airlock;

    /// @notice Launchpad governance factory (Airlock module — excess → `excessSupplyLocker`).
    address public governanceFactory;

    /// @notice Doppler multicurve pool initializer (Airlock module).
    address public poolInitializer;

    /// @notice Doppler liquidity migrator (Airlock module).
    address public liquidityMigrator;

    /// @notice Rehype bonding-hook initializer (fee routing during bonding).
    address public rehypeHookInitializer;

    /// @notice Rehype migrator hook (fee routing after graduation).
    address public rehypeHookMigrator;

    /// @notice Global excess-supply receiver (`LaunchpadGovernanceFactory` timelock slot).
    address public excessSupplyLocker;

    /// @notice HP Treasury — 95% StreamableFeesLocker beneficiary after migrate.
    address public hpTreasury;

    /// @notice Privileged call relay (factories / registry require `msg.sender == Orchestrator`).
    IOrchestrator public orchestrator;

    /// @notice Per-market FeeRouter factory (Orchestrator-gated).
    FeeRouterFactory public feeRouterFactory;

    /// @notice Canonical player market registry (Orchestrator-gated).
    IPlayerSetRegistry public playerSetRegistry;

    // -------------------------------------------------------------------------
    //  Queue storage
    // -------------------------------------------------------------------------

    QueueEntry[] private _queue;

    /// @dev `playerId → index + 1` (`0` = not queued).
    mapping(bytes32 playerId => uint256) private _queueIndexPlusOne;

    /// @dev In-flight oracle correlation.
    mapping(bytes32 requestId => OracleKind) private _oracleKind;
    mapping(bytes32 requestId => bytes32) private _oracleSeasonId;
    mapping(bytes32 requestId => bytes32) private _oraclePlayerId;

    // -------------------------------------------------------------------------
    //  Construction
    // -------------------------------------------------------------------------

    /**
     * @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
     * @dev `CVM_ROUTER` must already be registered on AddressProvider (oracle set first).
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address addressProvider_)
        AddressBook(addressProvider_)
        Ownable(msg.sender)
        Oracle(_cvmRouter(addressProvider_))
        RateLimit(DEFAULT_DEPLOY_COOLDOWN)
    {
        if (addressProvider_ == address(0)) revert Errors.ZeroAddress();
        _disableInitializers();
    }

    /**
     * @notice Proxy init: default Doppler config, queue wait; resolve deps; ownership → Orchestrator.
     * @dev AddressProvider must already hold Orchestrator, factories, registry, and Doppler modules.
     *      This proxy must also hold `AUTHORIZED_CONTRACT` on Orchestrator for deploy relays.
     */
    function initialize() external initializer {
        __DopplerConfig_init();
        queueWait = DEFAULT_QUEUE_WAIT;

        address orch = _getAddress(_addressKey(Addresses.ORCHESTRATOR));
        orchestrator = IOrchestrator(orch);
        feeRouterFactory = FeeRouterFactory(_getAddress(_addressKey(Addresses.FEE_ROUTER_FACTORY)));
        playerSetRegistry = IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));
        vaultFactory = _getAddress(_addressKey(Addresses.PLAYER_VAULT_FACTORY));

        tokenFactory = _getAddress(_addressKey(Addresses.DN404_FACTORY));
        airlock = _getAddress(_addressKey(Addresses.DOPPLER_AIRLOCK));
        governanceFactory = _getAddress(_addressKey(Addresses.LAUNCHPAD_GOVERNANCE_FACTORY));
        poolInitializer = _getAddress(_addressKey(Addresses.DOPPLER_HOOK_INITIALIZER));
        liquidityMigrator = _getAddress(_addressKey(Addresses.DOPPLER_HOOK_MIGRATOR));
        rehypeHookInitializer = _getAddress(_addressKey(Addresses.REHYPE_DOPPLER_HOOK_INITIALIZER));
        rehypeHookMigrator = _getAddress(_addressKey(Addresses.REHYPE_DOPPLER_HOOK_MIGRATOR));
        excessSupplyLocker = _getAddress(_addressKey(Addresses.EXCESS_SUPPLY_LOCKER));
        hpTreasury = _getAddress(_addressKey(Addresses.HP_TREASURY));

        _transferOwnership(orch);
    }

    /// @dev Resolve immutable CVM router at impl deploy (AddressBook not yet usable in base ctor list).
    function _cvmRouter(address addressProvider_) private view returns (address router) {
        router = AddressProvider(payable(addressProvider_)).get(keccak256(bytes(Addresses.CVM_ROUTER)));
        if (router == address(0)) revert Errors.ZeroAddress();
    }

    // -------------------------------------------------------------------------
    //  Admin
    // -------------------------------------------------------------------------

    /**
     * @notice Update CREATE2/CREATE3 deployers + Airlock (vanity args / create path).
     * @dev Defaults are resolved from AddressProvider in `initialize`; owner may override.
     */
    function configureDeployModules(address tokenFactory_, address vaultFactory_, address airlock_) external onlyOwner {
        if (tokenFactory_ == address(0) || vaultFactory_ == address(0) || airlock_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        tokenFactory = tokenFactory_;
        vaultFactory = vaultFactory_;
        airlock = airlock_;
        emit Events.DeployModulesConfigured(tokenFactory_, vaultFactory_, airlock_);
    }

    /**
     * @notice Update Airlock governance / pool / migrator / rehype module addresses.
     * @dev Defaults are resolved from AddressProvider in `initialize`; owner may override.
     */
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

    /**
     * @notice Update Launchpad excess recipient + HP Treasury beneficiary.
     * @dev `excessSupplyLocker` is encoded into `governanceFactoryData` at create time.
     */
    function configureLaunchpadRecipients(address excessSupplyLocker_, address hpTreasury_) external onlyOwner {
        if (excessSupplyLocker_ == address(0) || hpTreasury_ == address(0)) revert Errors.ZeroAddress();
        excessSupplyLocker = excessSupplyLocker_;
        hpTreasury = hpTreasury_;
    }

    function setQueueWait(uint256 queueWait_) external onlyOwner {
        if (queueWait_ == 0) revert Errors.NotConfigured();
        uint256 previous = queueWait;
        queueWait = queueWait_;
        emit Events.QueueWaitUpdated(previous, queueWait_);
    }

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
    //  Intake / review
    // -------------------------------------------------------------------------

    /// @inheritdoc IDopplerLocker
    function queueAssets(bytes32 seasonId, bytes32[] calldata playerIds) external onlyOwner {
        if (seasonId == bytes32(0)) revert Errors.ZeroId();

        uint256 added;
        uint256 length = playerIds.length;
        if (length > METADATA_BATCH_SIZE) revert Errors.TooManyPlayers(METADATA_BATCH_SIZE);
        for (uint256 i; i < length; ++i) {
            bytes32 playerId = playerIds[i];
            if (playerId == bytes32(0)) continue;
            if (_queueIndexPlusOne[playerId] != 0) continue;

            _queueIndexPlusOne[playerId] = _queue.length + 1;
            _queue.push(
                QueueEntry({
                    playerId: playerId,
                    seasonId: seasonId,
                    name: "",
                    symbol: "",
                    metadataSet: false,
                    queuedAt: 0,
                    status: QueueStatus.AwaitingMetadata,
                    tokenSalt: bytes32(0),
                    tokenPredicted: address(0),
                    vaultSalt: bytes32(0),
                    vaultPredicted: address(0)
                })
            );
            unchecked {
                ++added;
            }
        }

        uint256 promoted = _promoteReadyToQueue();
        uint256 awaiting = _requestAwaitingMetadata();

        emit Events.AssetsQueued(seasonId, added, promoted, awaiting, _queue.length);
    }

    /// @inheritdoc IDopplerLocker
    function unqueueAsset(bytes32 playerId) external onlyOwner {
        QueueEntry storage e = _entry(playerId);
        if (e.status != QueueStatus.Queued) revert Errors.BadQueueStatus(playerId, uint8(e.status));

        _removeFromQueue(playerId);
        emit Events.AssetUnqueued(playerId);
    }

    /// @inheritdoc IDopplerLocker
    function editMetadata(bytes32 playerId, string calldata name, string calldata symbol) external onlyOwner {
        if (bytes(name).length == 0) revert Errors.EmptyName();
        if (bytes(symbol).length == 0) revert Errors.EmptySymbol();

        QueueEntry storage e = _entry(playerId);
        if (e.status != QueueStatus.Queued) revert Errors.BadQueueStatus(playerId, uint8(e.status));

        e.name = name;
        e.symbol = symbol;
        e.metadataSet = true;
        e.queuedAt = uint64(block.timestamp);

        emit Events.PlayerMetadataUpdated(playerId, name, symbol);
    }

    // -------------------------------------------------------------------------
    //  Deploy kickoff (public, rate-limited)
    // -------------------------------------------------------------------------

    /// @inheritdoc IDopplerLocker
    function deployAssets() external rateLimited returns (bytes32 requestId) {
        if (tokenFactory == address(0) || vaultFactory == address(0) || airlock == address(0)) {
            revert Errors.NotConfigured();
        }

        uint256 length = _queue.length;
        uint256 wait_ = queueWait;

        for (uint256 i; i < length; ++i) {
            QueueEntry storage e = _queue[i];
            if (e.status != QueueStatus.Queued) continue;
            if (!e.metadataSet) continue;
            if (block.timestamp < uint256(e.queuedAt) + wait_) continue;

            bytes32 initCodeHash = _tokenInitCodeHash(e);
            bytes memory args = abi.encode(
                VanityDeployKind.Asset,
                e.playerId, // seed
                tokenFactory,
                initCodeHash,
                vaultFactory,
                address(0)
            );

            requestId = _sendOracleRequest(CvmJob.VanitySalts, args);
            _oracleKind[requestId] = OracleKind.VanitySalts;
            _oraclePlayerId[requestId] = e.playerId;
            e.status = QueueStatus.AwaitingSalts;

            emit Events.VanitySaltsRequested(requestId, e.playerId, initCodeHash);
            return requestId;
        }

        revert Errors.NothingReady();
    }

    // -------------------------------------------------------------------------
    //  Oracle callback
    // -------------------------------------------------------------------------

    /// @inheritdoc Oracle
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        OracleKind kind = _oracleKind[requestId];
        if (kind == OracleKind.None) revert Errors.UnknownOracleRequest(requestId);

        delete _oracleKind[requestId];

        if (kind == OracleKind.PlayerMetadata) {
            _fulfillPlayerMetadata(requestId, response, err);
        } else {
            _fulfillVanitySalts(requestId, response, err);
        }
    }

    // -------------------------------------------------------------------------
    //  Views
    // -------------------------------------------------------------------------

    function queueCount() external view returns (uint256) {
        return _queue.length;
    }

    function isQueued(bytes32 playerId) external view returns (bool) {
        return _queueIndexPlusOne[playerId] != 0;
    }

    function queueEntry(bytes32 playerId) external view returns (QueueEntry memory) {
        return _entry(playerId);
    }

    function queueAt(uint256 index) external view returns (QueueEntry memory) {
        return _queue[index];
    }

    /// @notice Earliest timestamp when `playerId` becomes deploy-eligible (`0` if unknown).
    function deployUnlockAt(bytes32 playerId) external view returns (uint256) {
        QueueEntry storage e = _entry(playerId);
        if (e.status != QueueStatus.Queued || e.queuedAt == 0) return 0;
        return uint256(e.queuedAt) + queueWait;
    }

    // -------------------------------------------------------------------------
    //  Internal — intake
    // -------------------------------------------------------------------------

    function _promoteReadyToQueue() private returns (uint256 promoted) {
        uint256 length = _queue.length;
        uint64 now_ = uint64(block.timestamp);
        for (uint256 i; i < length; ++i) {
            QueueEntry storage e = _queue[i];
            if (e.status != QueueStatus.ReadyToQueue) continue;
            e.status = QueueStatus.Queued;
            e.queuedAt = now_;
            unchecked {
                ++promoted;
            }
        }
    }

    /**
     * @dev PlayerMetadata requests for `AwaitingMetadata` rows, grouped by `seasonId`
     *      and paginated to `METADATA_BATCH_SIZE` playerIds per request.
     */
    function _requestAwaitingMetadata() private returns (uint256 awaiting) {
        uint256 length = _queue.length;
        bytes32[] memory seen = new bytes32[](length);
        uint256 seenN;

        for (uint256 i; i < length; ++i) {
            QueueEntry storage e = _queue[i];
            if (e.status != QueueStatus.AwaitingMetadata) continue;

            bool already;
            for (uint256 s; s < seenN; ++s) {
                if (seen[s] == e.seasonId) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            seen[seenN] = e.seasonId;
            unchecked {
                ++seenN;
            }

            bytes32[] memory ids = _collectBySeason(e.seasonId, QueueStatus.AwaitingMetadata);
            if (ids.length == 0) continue;

            unchecked {
                awaiting += ids.length;
            }
            _sendMetadataPages(e.seasonId, ids);
        }
    }

    /// @dev Slice `ids` into pages of `METADATA_BATCH_SIZE` and open one CVM request each.
    function _sendMetadataPages(bytes32 seasonId, bytes32[] memory ids) private {
        uint256 pageSize = METADATA_BATCH_SIZE;
        uint256 total = ids.length;
        for (uint256 offset; offset < total;) {
            uint256 end = offset + pageSize;
            if (end > total) end = total;
            uint256 pageLen = end - offset;

            bytes32[] memory page = new bytes32[](pageLen);
            for (uint256 j; j < pageLen; ++j) {
                page[j] = ids[offset + j];
            }

            bytes memory args = abi.encode(seasonId, page);
            bytes32 requestId = _sendOracleRequest(CvmJob.PlayerMetadata, args);
            _oracleKind[requestId] = OracleKind.PlayerMetadata;
            _oracleSeasonId[requestId] = seasonId;
            emit Events.PlayerMetadataRequested(requestId, seasonId, pageLen);

            unchecked {
                offset = end;
            }
        }
    }

    function _fulfillPlayerMetadata(bytes32 requestId, bytes memory response, bytes memory err) private {
        bytes32 seasonId = _oracleSeasonId[requestId];
        delete _oracleSeasonId[requestId];

        emit Events.PlayerMetadataFulfilled(requestId, seasonId, err);
        if (err.length != 0 || response.length == 0) return;

        (bytes32 respSeason, bytes32[] memory playerIds, string[] memory names, string[] memory symbols) =
            abi.decode(response, (bytes32, bytes32[], string[], string[]));

        if (respSeason != seasonId) return;
        if (playerIds.length != names.length || playerIds.length != symbols.length) return;

        uint256 length = playerIds.length;
        for (uint256 i; i < length; ++i) {
            bytes32 playerId = playerIds[i];
            uint256 idxPlus = _queueIndexPlusOne[playerId];
            if (idxPlus == 0) continue;

            QueueEntry storage e = _queue[idxPlus - 1];
            if (e.seasonId != seasonId) continue;
            if (e.status != QueueStatus.AwaitingMetadata) continue;
            if (bytes(names[i]).length == 0 || bytes(symbols[i]).length == 0) continue;

            e.name = names[i];
            e.symbol = symbols[i];
            e.metadataSet = true;
            e.status = QueueStatus.ReadyToQueue;

            emit Events.PlayerMetadataUpdated(playerId, names[i], symbols[i]);
        }
    }

    // -------------------------------------------------------------------------
    //  Internal — vanity salts
    // -------------------------------------------------------------------------

    function _fulfillVanitySalts(bytes32 requestId, bytes memory response, bytes memory err) private {
        bytes32 playerId = _oraclePlayerId[requestId];
        delete _oraclePlayerId[requestId];

        QueueEntry storage e = _entry(playerId);

        if (err.length != 0 || response.length == 0) {
            if (e.status == QueueStatus.AwaitingSalts) e.status = QueueStatus.Queued;
            return;
        }

        (
            VanityDeployKind kind,
            bytes32 tokenSalt,
            address tokenPredicted,
            bytes32 vaultSalt,
            address vaultPredicted,
            ,
        ) = abi.decode(response, (VanityDeployKind, bytes32, address, bytes32, address, bytes32, address));

        if (kind != VanityDeployKind.Asset || tokenSalt == bytes32(0) || vaultSalt == bytes32(0)) {
            if (e.status == QueueStatus.AwaitingSalts) e.status = QueueStatus.Queued;
            return;
        }

        e.tokenSalt = tokenSalt;
        e.tokenPredicted = tokenPredicted;
        e.vaultSalt = vaultSalt;
        e.vaultPredicted = vaultPredicted;
        e.status = QueueStatus.DeployReady;

        _onDeployReady(e);
    }

    /**
     * @dev Atomic market deploy in the oracle fulfill callback:
     *      1) FeeRouter (via Orchestrator)
     *      2) Airlock.create (direct)
     *      3) PlayerVault + stToken (via Orchestrator)
     *      4) PlayerSetRegistry.addPlayerSet + addVaultData (via Orchestrator)
     *
     *      Prerequisites / follow-ups (do not skip when wiring production intake):
     *        - DopplerLocker proxy MUST hold Orchestrator `AUTHORIZED_CONTRACT` so `_exec`
     *          can reach FeeRouterFactory / PlayerVaultFactory / PlayerSetRegistry.
     *        - AddressProvider MUST hold DN404 / Airlock / hook / migrator module addresses
     *          before `initialize` (or owner must `configureDeployModules` /
     *          `configureDopplerModules` afterwards).
     *        - Numeraire is native ETH (`address(0)`). Airlock treats `address(0)` as ETH
     *          (see `Airlock.migrate` / fee collect). Switch to WETH9 only if the recipe
     *          moves to an ERC-20 numeraire.
     *        - League / PbrFeeHub: intake currently has `seasonId` only. Until
     *          EligibilityVerifier (or queueAssets) supplies `leagueId`:
     *            * FeeRouter is created with `pbrFeeHub = address(0)` (even-split / no hub)
     *            * PlayerSetRegistry gets `TournamentData.leagueId = 0` and empty
     *              `activeTournaments`
     *        - After league is known: `TournamentRegistry.registerVaults(leagueId, [vault])`
     *          so TransferLocker / treasury membership sees the vault; also
     *          `setLeagueId` / hub rewiring on FeeRouter as needed.
     *        - Callback gas: full deploy runs inside CvmRouter `maxCallbackGasLimit`.
     */
    function _onDeployReady(QueueEntry storage e) private {
        _requireDeployModules();

        // 1) FeeRouter — buyback destination for Rehype fees.
        //    TODO(league): pass `TournamentRegistry.pbrFeeHubOf(leagueId)` once intake has leagueId.
        address feeRouter = _deployFeeRouter(e.playerId);

        // 2) Airlock.create — DN404 + bonding pool. Numeraire = native ETH (`address(0)`).
        address asset = _deployBondingMarket(e, feeRouter);

        // 3) PlayerVault + stToken (stToken salt is deterministic; vault salt is vanity-mined).
        (address vault, address stToken) = _deployVault(e, asset);

        // 4) Registry — token + Doppler set, then vault set.
        //    TODO(league): set TournamentData.leagueId + activeTournaments; then
        //    TournamentRegistry.registerVaults(leagueId, [vault]) via Orchestrator.
        _registerPlayerSet(e, asset, feeRouter, vault, stToken);

        e.status = QueueStatus.Deployed;
        emit Events.AssetDeployed(e.playerId, asset, vault, feeRouter, stToken);
    }

    function _requireDeployModules() private view {
        if (
            tokenFactory == address(0) || vaultFactory == address(0) || airlock == address(0)
                || governanceFactory == address(0) || poolInitializer == address(0) || liquidityMigrator == address(0)
                || rehypeHookInitializer == address(0) || rehypeHookMigrator == address(0)
        ) {
            revert Errors.NotConfigured();
        }
    }

    function _deployFeeRouter(bytes32 playerId) private returns (address feeRouter) {
        feeRouter = abi.decode(
            _exec(address(feeRouterFactory), abi.encodeCall(FeeRouterFactory.create, (playerId, address(0)))),
            (address)
        );
    }

    function _deployBondingMarket(QueueEntry storage e, address feeRouter) private returns (address asset) {
        CreateParams memory params = DopplerTypes.buildCreateParams(
            _dopplerModules(), marketLaunchConfig(), e.name, e.symbol, feeRouter, e.tokenSalt
        );
        (asset,,,,) = Airlock(payable(airlock)).create(params);
        if (asset != e.tokenPredicted) revert Errors.DeployAddressMismatch(e.tokenPredicted, asset);
    }

    function _deployVault(QueueEntry storage e, address asset) private returns (address vault, address stToken) {
        bytes32 stTokenSalt =
            PlayerVaultFactory(vaultFactory).makeSalt(bytes11(keccak256(abi.encodePacked(e.playerId, bytes2("st")))));
        (vault, stToken) = abi.decode(
            _exec(
                vaultFactory,
                abi.encodeCall(
                    PlayerVaultFactory.create, (e.playerId, asset, e.name, e.symbol, e.vaultSalt, stTokenSalt)
                )
            ),
            (address, address)
        );
        if (vault != e.vaultPredicted) revert Errors.DeployAddressMismatch(e.vaultPredicted, vault);
    }

    function _registerPlayerSet(
        QueueEntry storage e,
        address asset,
        address feeRouter,
        address vault,
        address stToken
    ) private {
        PoolKey memory poolKey;
        (,,,,, poolKey,) = DopplerHookInitializer(payable(poolInitializer)).getState(asset);

        bytes32[] memory activeTournaments;
        _exec(
            address(playerSetRegistry),
            abi.encodeCall(
                IPlayerSetRegistry.addPlayerSet,
                (
                    e.playerId,
                    TokenData({ token: asset, name: e.name, symbol: e.symbol }),
                    TournamentData({ leagueId: bytes32(0), activeTournaments: activeTournaments }),
                    DopplerData({
                        activePool: poolKey,
                        hookDoppler: rehypeHookInitializer,
                        hookMigrator: rehypeHookMigrator,
                        feeRouter: feeRouter
                    })
                )
            )
        );
        _exec(
            address(playerSetRegistry),
            abi.encodeCall(
                IPlayerSetRegistry.addVaultData,
                (e.playerId, VaultData({ playerVault: vault, stToken: stToken, isUtilized: false }))
            )
        );
    }

    /// @dev Local module wiring for `DopplerTypes.buildCreateParams` (numeraire = native ETH).
    function _dopplerModules() private view returns (DopplerTypes.DopplerModules memory m) {
        if (excessSupplyLocker == address(0) || hpTreasury == address(0)) revert Errors.ZeroAddress();
        m.airlock = airlock;
        m.tokenFactory = tokenFactory;
        m.governanceFactory = governanceFactory;
        m.poolInitializer = poolInitializer;
        m.liquidityMigrator = liquidityMigrator;
        m.rehypeHookInitializer = rehypeHookInitializer;
        m.rehypeHookMigrator = rehypeHookMigrator;
        m.feeRouterFactory = address(feeRouterFactory);
        m.numeraire = address(0); // native ETH — Airlock convention
        m.integrator = address(orchestrator);
        m.airlockOwner = Ownable(airlock).owner();
        m.excessSupplyLocker = excessSupplyLocker;
        m.hpTreasury = hpTreasury;
    }

    function _exec(address target, bytes memory data) private returns (bytes memory) {
        return orchestrator.execute(target, 0, data);
    }

    // -------------------------------------------------------------------------
    //  Internal — helpers
    // -------------------------------------------------------------------------

    function _entry(bytes32 playerId) private view returns (QueueEntry storage e) {
        uint256 idxPlus = _queueIndexPlusOne[playerId];
        if (idxPlus == 0) revert Errors.NotQueued(playerId);
        e = _queue[idxPlus - 1];
    }

    function _collectBySeason(bytes32 seasonId, QueueStatus status) private view returns (bytes32[] memory ids) {
        uint256 length = _queue.length;
        uint256 n;
        for (uint256 i; i < length; ++i) {
            QueueEntry storage e = _queue[i];
            if (e.seasonId == seasonId && e.status == status) {
                unchecked {
                    ++n;
                }
            }
        }

        ids = new bytes32[](n);
        uint256 w;
        for (uint256 i; i < length; ++i) {
            QueueEntry storage e = _queue[i];
            if (e.seasonId == seasonId && e.status == status) {
                ids[w] = e.playerId;
                unchecked {
                    ++w;
                }
            }
        }
    }

    function _removeFromQueue(bytes32 playerId) private {
        uint256 idxPlus = _queueIndexPlusOne[playerId];
        if (idxPlus == 0) revert Errors.NotQueued(playerId);

        uint256 index = idxPlus - 1;
        uint256 last = _queue.length - 1;

        if (index != last) {
            QueueEntry storage moved = _queue[last];
            _queue[index] = moved;
            _queueIndexPlusOne[moved.playerId] = index + 1;
        }

        _queue.pop();
        delete _queueIndexPlusOne[playerId];
    }

    function _tokenInitCodeHash(QueueEntry storage e) private view returns (bytes32) {
        return MineSalt.dn404InitCodeHash(
            MineSalt.Dn404DeployParams({
                name: e.name,
                symbol: e.symbol,
                initialSupply: initialSupply,
                airlock: airlock,
                baseURI: baseURI,
                unit: dn404Unit
            })
        );
    }
}
