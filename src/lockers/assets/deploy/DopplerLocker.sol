// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { Oracle } from "@base/abstract/Oracle.sol";
import { RateLimit } from "@base/abstract/RateLimit.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { DeploymentsErrors as Errors } from "@errors/governance/DeploymentsErrors.sol";
import { DeploymentsEvents as Events } from "@events/governance/DeploymentsEvents.sol";
import { IDopplerConfig } from "@interfaces/governance/IDopplerConfig.sol";
import { IDopplerLocker } from "@interfaces/governance/IDopplerLocker.sol";
import { IOrchestrator } from "@interfaces/IOrchestrator.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";
import { DopplerData, PlayerSet, TokenData, TournamentData, VaultData } from "@types/PlayerSetTypes.sol";
import { AddressProvider } from "@src/AddressProvider.sol";
import { FeeRouterFactory } from "@markets/factories/FeeRouterFactory.sol";
import { PlayerVault } from "@vaults/PlayerVault.sol";
import { PlayerVaultFactory } from "@vaults/factories/PlayerVaultFactory.sol";

import { Airlock, CreateParams } from "@doppler/src/Airlock.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { IExcessSupplyLocker } from "@interfaces/governance/IExcessSupplyLocker.sol";

/// @dev Narrow views — avoid importing Rehype/DopplerHookInitializer (pulls Quoter `=0.8.26`).
interface IDopplerHookInitializerView {
    function getState(address asset)
        external
        view
        returns (
            address numeraire,
            uint256 totalTokensOnBondingCurve,
            address dopplerHook,
            bytes memory graduationDopplerHookCalldata,
            uint8 status,
            PoolKey memory poolKey,
            int24 farTick
        );
}

interface IRehypePoolInfoView {
    function getPoolInfo(PoolId poolId) external view returns (address asset, address numeraire, address buybackDst);
}

/**
 * @title DopplerLocker
 * @notice Intake → metadata → explicit 24h queue → FinalConfig → deploy handoff.
 * @dev Dual CVM jobs via `Oracle._sendOracleRequest(job, args)`:
 *        1) `queueAssets` → `CvmJob.PlayerMetadata` (`seasonId`, `playerIds[]`)
 *        2) `deployAssets` (rate-limited) → `CvmJob.FinalConfig` once wait elapsed
 *
 *      Flow:
 *        DeployTournament (DOMESTIC_LEAGUE) first → `pbrFeeHubOf(leagueId)` live
 *        → owner `queueAssets(leagueId, seasonId, playerIds)` → `AwaitingMetadata` + metadata request
 *        → fulfill → `ReadyToQueue` (name/symbol; clock not started)
 *        → next `queueAssets` promotes `ReadyToQueue` → `Queued` (`queuedAt = now`)
 *        → owner may `editMetadata` / `unqueueAsset` during the 24h window
 *        → anyone calls `deployAssets` after wait; RateLimit gates frequency
 *        → FinalConfig: oracle pins IPFS metadata + mines salts + returns `baseURI`
 *        → fulfill → `_onDeployReady` (FeeRouter w/ hub → Airlock → Vault → PlayerSet + registerVaults
 *          → ExcessSupplyLocker.allocate)
 *        → oracle/validation failure: re-queue for a new FinalConfig (`retryWait`, default 5m)
 *        → Airlock not ours yet (create fail / salt frontrun): new FinalConfig after `retryWait`
 *        → Airlock already ours (integrator + FeeRouter buybackDst): resume vault/registry after `retryWait`
 *        → post-Airlock steps are idempotent; success removes the entry from the queue
 *        → after `maxDeployAttempts` failures: `DeployFailed` + event (owner `resetFailedDeploy`)
 *
 *      Factory / registry writes relay through `Orchestrator.execute` (this proxy must hold
 *      `AUTHORIZED_CONTRACT`). `Airlock.create` is called directly.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract DopplerLocker is Initializable, AddressBook, Ownable, Oracle, RateLimit, IDopplerLocker {
    // -------------------------------------------------------------------------
    //  Types
    // -------------------------------------------------------------------------

    enum QueueStatus {
        None,
        /// @dev Intake; waiting on PlayerMetadata.
        AwaitingMetadata,
        /// @dev Metadata set; waiting for owner to start the 24h window via `queueAssets`.
        ReadyToQueue,
        /// @dev In the review window (`queuedAt + active wait`).
        Queued,
        /// @dev FinalConfig request in flight.
        AwaitingFinalConfig,
        /// @dev Salts/`baseURI` stored; deploy in progress or waiting to resume after a partial failure.
        DeployReady,
        Deployed,
        /// @dev Automatic retries exhausted; owner must `resetFailedDeploy`.
        DeployFailed
    }

    enum OracleKind {
        None,
        PlayerMetadata,
        /// @dev FinalConfig fulfill → store salts/`baseURI` → `_onDeployReady`.
        Deploy
    }

    struct QueueEntry {
        bytes32 playerId;
        /// @dev Domestic league id (`==` DeployTournament `tournamentId` for DOMESTIC_LEAGUE).
        bytes32 leagueId;
        /// @dev Tournament-calendar HPID (`tmcl` after HPID decode).
        bytes32 seasonId;
        string name;
        string symbol;
        /// @dev DN404 metadata prefix from FinalConfig (`ipfs://…/`); empty until fulfill.
        string baseURI;
        bool metadataSet;
        uint64 queuedAt;
        /// @dev Per-entry wait override (`0` → use `queueWait`; set to `retryWait` on deploy fail).
        uint64 waitSeconds;
        QueueStatus status;
        bytes32 tokenSalt;
        address tokenPredicted;
        bytes32 vaultSalt;
        address vaultPredicted;
        /// @dev Failed deploy attempts toward `maxDeployAttempts` (oracle + onchain).
        uint8 deployAttempts;
    }

    // -------------------------------------------------------------------------
    //  Constants
    // -------------------------------------------------------------------------

    uint256 public constant DEFAULT_QUEUE_WAIT = 24 hours;
    uint256 public constant DEFAULT_RETRY_WAIT = 5 minutes;
    uint256 public constant DEFAULT_DEPLOY_COOLDOWN = 5 minutes;
    uint256 public constant DEFAULT_MAX_DEPLOY_ATTEMPTS = 5;
    /// @notice Max players per `queueAssets` call and per PlayerMetadata oracle page.
    uint256 public constant METADATA_BATCH_SIZE = 50;

    // -------------------------------------------------------------------------
    //  Immutables / config
    // -------------------------------------------------------------------------

    /// @notice Seconds after `Queued` before `deployAssets` may request FinalConfig (first attempt).
    uint256 public queueWait;

    /// @notice Seconds after a failed deploy fulfill before `deployAssets` may retry.
    uint256 public retryWait;

    /// @notice Max automatic deploy failures before `DeployFailed` (owner reset required).
    uint256 public maxDeployAttempts;

    /// @notice Shared launch recipe + Doppler module addresses (separate admin surface).
    IDopplerConfig public dopplerConfig;

    /// @notice Privileged call relay (factories / registry require `msg.sender == Orchestrator`).
    IOrchestrator public orchestrator;

    /// @notice Per-market FeeRouter factory (Orchestrator-gated).
    FeeRouterFactory public feeRouterFactory;

    /// @notice Canonical player market registry (Orchestrator-gated).
    IPlayerSetRegistry public playerSetRegistry;

    /// @notice League hubs / vault membership SoT (Orchestrator-gated).
    ITournamentRegistry public tournamentRegistry;

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
     * @notice Proxy init: queue waits; resolve deps + `DopplerConfig`; ownership → Orchestrator.
     * @dev AddressProvider must hold Orchestrator, factories, registries, and `DOPPLER_CONFIG`.
     *      This proxy must also hold `AUTHORIZED_CONTRACT` on Orchestrator for deploy relays.
     */
    function initialize() external initializer {
        queueWait = DEFAULT_QUEUE_WAIT;
        retryWait = DEFAULT_RETRY_WAIT;
        maxDeployAttempts = DEFAULT_MAX_DEPLOY_ATTEMPTS;

        address orch = _getAddress(_addressKey(Addresses.ORCHESTRATOR));
        orchestrator = IOrchestrator(orch);
        feeRouterFactory = FeeRouterFactory(_getAddress(_addressKey(Addresses.FEE_ROUTER_FACTORY)));
        playerSetRegistry = IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));
        tournamentRegistry = ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
        dopplerConfig = IDopplerConfig(_getAddress(_addressKey(Addresses.DOPPLER_CONFIG)));

        _transferOwnership(orch);
    }

    /// @dev Resolve immutable CVM router at impl deploy (AddressBook not yet usable in base ctor list).
    function _cvmRouter(address addressProvider_) private view returns (address router) {
        router = AddressProvider(payable(addressProvider_)).get(keccak256(bytes(Addresses.CVM_ROUTER)));
        if (router == address(0)) revert Errors.ZeroAddress();
    }

    // -------------------------------------------------------------------------
    //  Admin (queue / deploy ops — launch recipe + modules live on `DopplerConfig`)
    // -------------------------------------------------------------------------

    function setQueueWait(uint256 queueWait_) external onlyOwner {
        if (queueWait_ == 0) revert Errors.NotConfigured();
        uint256 previous = queueWait;
        queueWait = queueWait_;
        emit Events.QueueWaitUpdated(previous, queueWait_);
    }

    function setRetryWait(uint256 retryWait_) external onlyOwner {
        if (retryWait_ == 0) revert Errors.NotConfigured();
        uint256 previous = retryWait;
        retryWait = retryWait_;
        emit Events.RetryWaitUpdated(previous, retryWait_);
    }

    function setMaxDeployAttempts(uint256 maxDeployAttempts_) external onlyOwner {
        if (maxDeployAttempts_ == 0 || maxDeployAttempts_ > type(uint8).max) revert Errors.NotConfigured();
        uint256 previous = maxDeployAttempts;
        maxDeployAttempts = maxDeployAttempts_;
        emit Events.MaxDeployAttemptsUpdated(previous, maxDeployAttempts_);
    }

    /**
     * @notice Clear `DeployFailed` so ops can redeploy after a bugfix.
     * @param keepSalts If true and salts/`baseURI` remain, resume as `DeployReady` (post-Airlock path).
     *        Otherwise clear salts and return to `Queued` with a short `retryWait` gate.
     */
    function resetFailedDeploy(bytes32 playerId, bool keepSalts) external onlyOwner {
        QueueEntry storage e = _entry(playerId);
        if (e.status != QueueStatus.DeployFailed) revert Errors.BadQueueStatus(playerId, uint8(e.status));

        e.deployAttempts = 0;
        e.queuedAt = uint64(block.timestamp);

        if (keepSalts && e.tokenPredicted != address(0) && bytes(e.baseURI).length != 0) {
            e.status = QueueStatus.DeployReady;
            e.waitSeconds = 0; // eligible immediately
        } else {
            e.baseURI = "";
            e.tokenSalt = bytes32(0);
            e.tokenPredicted = address(0);
            e.vaultSalt = bytes32(0);
            e.vaultPredicted = address(0);
            e.status = QueueStatus.Queued;
            e.waitSeconds = uint64(retryWait == 0 ? DEFAULT_RETRY_WAIT : retryWait);
        }
    }

    // -------------------------------------------------------------------------
    //  Intake / review
    // -------------------------------------------------------------------------

    /// @inheritdoc IDopplerLocker
    function queueAssets(bytes32 leagueId, bytes32 seasonId, bytes32[] calldata playerIds) external onlyOwner {
        if (leagueId == bytes32(0) || seasonId == bytes32(0)) revert Errors.ZeroId();
        // League must already be bootstrapped via DeployTournament (hub + treasury registered).
        if (!tournamentRegistry.tournamentExists(leagueId)) revert Errors.NotConfigured();
        if (tournamentRegistry.pbrFeeHubOf(leagueId) == address(0)) revert Errors.HubNotRegistered(leagueId);
        // Season must be open under this domestic league (`tournamentId == leagueId`).
        bytes32 seasonTournament = tournamentRegistry.tournamentIdOfSeason(seasonId);
        if (seasonTournament == bytes32(0)) revert Errors.SeasonNotRegistered(seasonId);
        if (seasonTournament != leagueId) revert Errors.LeagueMismatch(leagueId, seasonTournament);

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
                    leagueId: leagueId,
                    seasonId: seasonId,
                    name: "",
                    symbol: "",
                    baseURI: "",
                    metadataSet: false,
                    queuedAt: 0,
                    waitSeconds: 0,
                    status: QueueStatus.AwaitingMetadata,
                    tokenSalt: bytes32(0),
                    tokenPredicted: address(0),
                    vaultSalt: bytes32(0),
                    vaultPredicted: address(0),
                    deployAttempts: 0
                })
            );
            unchecked {
                ++added;
            }
        }

        uint256 promoted = _promoteReadyToQueue();
        uint256 awaiting = _requestAwaitingMetadata();

        emit Events.AssetsQueued(leagueId, seasonId, added, promoted, awaiting, _queue.length);
    }

    /// @inheritdoc IDopplerLocker
    function unqueueAsset(bytes32 playerId) external onlyOwner {
        QueueEntry storage e = _entry(playerId);
        if (e.status != QueueStatus.Queued && e.status != QueueStatus.DeployFailed) {
            revert Errors.BadQueueStatus(playerId, uint8(e.status));
        }

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
        // `baseURI` is set at FinalConfig (IPFS); clear any stale value if re-editing.
        e.baseURI = "";
        e.metadataSet = true;
        e.queuedAt = uint64(block.timestamp);
        e.waitSeconds = 0; // full `queueWait` after manual edit

        emit Events.PlayerMetadataUpdated(playerId, name, symbol, e.baseURI);
    }

    // -------------------------------------------------------------------------
    //  Deploy kickoff (public, rate-limited)
    // -------------------------------------------------------------------------

    /// @inheritdoc IDopplerLocker
    function deployAssets() external rateLimited returns (bytes32 requestId) {
        if (address(dopplerConfig) == address(0)) revert Errors.NotConfigured();
        if (
            dopplerConfig.tokenFactory() == address(0) || dopplerConfig.vaultFactory() == address(0)
                || dopplerConfig.airlock() == address(0)
        ) {
            revert Errors.NotConfigured();
        }

        uint256 length = _queue.length;

        // Prefer resuming a DeployReady entry (same salts/`baseURI`) before a new FinalConfig.
        for (uint256 i; i < length; ++i) {
            QueueEntry storage e = _queue[i];
            if (e.status != QueueStatus.DeployReady) continue;
            if (e.tokenPredicted == address(0) || bytes(e.baseURI).length == 0) continue;
            if (block.timestamp < uint256(e.queuedAt) + _deployWait(e)) continue;

            try this.executeDeploy(e.playerId) { }
            catch {
                _handleDeployFailure(e);
            }
            return bytes32(0);
        }

        for (uint256 i; i < length; ++i) {
            QueueEntry storage e = _queue[i];
            if (e.status != QueueStatus.Queued) continue;
            if (!e.metadataSet) continue;
            if (block.timestamp < uint256(e.queuedAt) + _deployWait(e)) continue;

            // Oracle pins IPFS metadata, hashes DN404 initcode with that baseURI, mines salts.
            IDopplerConfig cfg = dopplerConfig;
            bytes memory args = abi.encode(
                e.playerId, // seed
                cfg.tokenFactory(),
                cfg.vaultFactory(),
                cfg.airlock(),
                cfg.initialSupply(),
                cfg.dn404Unit(),
                e.name,
                e.symbol
            );

            requestId = _sendOracleRequest(CvmJob.FinalConfig, args);
            _oracleKind[requestId] = OracleKind.Deploy;
            _oraclePlayerId[requestId] = e.playerId;
            e.status = QueueStatus.AwaitingFinalConfig;

            emit Events.FinalConfigRequested(requestId, e.playerId);
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
            _fulfillDeploy(requestId, response, err);
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
        if (e.queuedAt == 0) return 0;
        if (e.status != QueueStatus.Queued && e.status != QueueStatus.DeployReady) return 0;
        return uint256(e.queuedAt) + _deployWait(e);
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
            e.waitSeconds = 0;
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
            e.baseURI = "";
            e.metadataSet = true;
            e.status = QueueStatus.ReadyToQueue;

            emit Events.PlayerMetadataUpdated(playerId, names[i], symbols[i], e.baseURI);
        }
    }

    // -------------------------------------------------------------------------
    //  Internal — deploy fulfill (IPFS baseURI + salts → market deploy)
    // -------------------------------------------------------------------------

    function _fulfillDeploy(bytes32 requestId, bytes memory response, bytes memory err) private {
        bytes32 playerId = _oraclePlayerId[requestId];
        delete _oraclePlayerId[requestId];

        QueueEntry storage e = _entry(playerId);
        if (e.status != QueueStatus.AwaitingFinalConfig) return;

        if (err.length != 0 || response.length == 0) {
            _requeueForFinalConfig(e);
            return;
        }

        // Commit salts/`baseURI` first (separate external call) so a later deploy revert does not
        // wipe predictions needed for idempotent resume.
        try this.applyFinalConfig(playerId, response) { }
        catch {
            _requeueForFinalConfig(e);
            return;
        }

        try this.executeDeploy(playerId) { }
        catch {
            _handleDeployFailure(e);
        }
    }

    /**
     * @notice Validate FinalConfig response and persist salts/`baseURI` as `DeployReady`.
     * @dev External so `_fulfillDeploy` can `try/catch` without reverting the CVM callback.
     */
    function applyFinalConfig(bytes32 playerId, bytes calldata response) external {
        if (msg.sender != address(this)) revert Errors.Unauthorized();

        QueueEntry storage e = _entry(playerId);
        if (e.status != QueueStatus.AwaitingFinalConfig) {
            revert Errors.BadQueueStatus(playerId, uint8(e.status));
        }

        (bytes32 tokenSalt, address tokenPredicted, bytes32 vaultSalt, address vaultPredicted, string memory baseURI_) =
            abi.decode(response, (bytes32, address, bytes32, address, string));

        if (
            tokenSalt == bytes32(0) || vaultSalt == bytes32(0) || tokenPredicted == address(0)
                || vaultPredicted == address(0) || bytes(baseURI_).length == 0
        ) {
            revert Errors.NotConfigured();
        }

        // Salts / predictions come from FinalConfig (oracle). Address match is enforced at Airlock.create /
        // vault CREATE3 (`DeployAddressMismatch` / `SaltOccupied` on resume).
        e.baseURI = baseURI_;
        e.tokenSalt = tokenSalt;
        e.tokenPredicted = tokenPredicted;
        e.vaultSalt = vaultSalt;
        e.vaultPredicted = vaultPredicted;
        e.status = QueueStatus.DeployReady;
        // Immediate fulfill attempt uses wait=0 via queuedAt unchanged from Queued era, or:
        e.queuedAt = uint64(block.timestamp);
        e.waitSeconds = 0;
    }

    /**
     * @notice Run idempotent FeeRouter → Airlock → vault → registry deploy for a `DeployReady` entry.
     * @dev External so fulfill / `deployAssets` can `try/catch` without reverting the caller.
     */
    function executeDeploy(bytes32 playerId) external {
        if (msg.sender != address(this)) revert Errors.Unauthorized();

        QueueEntry storage e = _entry(playerId);
        if (e.status != QueueStatus.DeployReady) revert Errors.BadQueueStatus(playerId, uint8(e.status));
        _onDeployReady(e);
    }

    /// @dev Oracle/validation / pre-Airlock miss — clear salts; re-queue or `DeployFailed` if capped.
    function _requeueForFinalConfig(QueueEntry storage e) private {
        bool exhausted = _noteDeployFailure(e);

        e.baseURI = "";
        e.tokenSalt = bytes32(0);
        e.tokenPredicted = address(0);
        e.vaultSalt = bytes32(0);
        e.vaultPredicted = address(0);

        if (exhausted) return; // status already `DeployFailed`

        uint256 wait_ = retryWait == 0 ? DEFAULT_RETRY_WAIT : retryWait;
        e.status = QueueStatus.Queued;
        e.queuedAt = uint64(block.timestamp);
        e.waitSeconds = uint64(wait_);
        emit Events.DeployRetryQueued(e.playerId, e.queuedAt, wait_, e.deployAttempts, uint8(_maxDeployAttempts()));
    }

    /**
     * @dev Branch on whether Airlock.create already landed for this entry:
     *      - our market at `tokenPredicted` → keep salts, resume vault/registry
     *      - otherwise (create revert / salt frontrun) → new FinalConfig
     */
    function _handleDeployFailure(QueueEntry storage e) private {
        if (_isOurBondingMarket(e.playerId, e.tokenPredicted)) {
            _scheduleDeployResume(e);
        } else {
            _requeueForFinalConfig(e);
        }
    }

    /// @dev Post-Airlock miss — keep salts/`baseURI` and resume `executeDeploy` after `retryWait`.
    function _scheduleDeployResume(QueueEntry storage e) private {
        if (_noteDeployFailure(e)) return;

        uint256 wait_ = retryWait == 0 ? DEFAULT_RETRY_WAIT : retryWait;
        e.status = QueueStatus.DeployReady;
        e.queuedAt = uint64(block.timestamp);
        e.waitSeconds = uint64(wait_);
        emit Events.DeployRetryQueued(e.playerId, e.queuedAt, wait_, e.deployAttempts, uint8(_maxDeployAttempts()));
    }

    /// @dev Increment attempt counter; on cap set `DeployFailed` and return true.
    function _noteDeployFailure(QueueEntry storage e) private returns (bool exhausted) {
        uint8 next = e.deployAttempts + 1;
        e.deployAttempts = next;
        uint256 max_ = _maxDeployAttempts();
        if (next >= max_) {
            e.status = QueueStatus.DeployFailed;
            emit Events.DeployAttemptsExhausted(e.playerId, next);
            return true;
        }
        return false;
    }

    function _maxDeployAttempts() private view returns (uint256) {
        return maxDeployAttempts == 0 ? DEFAULT_MAX_DEPLOY_ATTEMPTS : maxDeployAttempts;
    }

    /**
     * @dev True when `asset` is our Airlock market: Orchestrator integrator **and** Rehype
     *      `buybackDst` equals the FeeRouter from `feeRouterFactory` for `playerId`.
     */
    function _isOurBondingMarket(bytes32 playerId, address asset) private view returns (bool) {
        address expectedFeeRouter = feeRouterFactory.feeRouterOf(playerId);
        if (asset == address(0) || asset.code.length == 0 || expectedFeeRouter == address(0)) return false;

        IDopplerConfig cfg = dopplerConfig;
        (,,,,, address pool,,,, address integrator) = Airlock(payable(cfg.airlock())).getAssetData(asset);
        if (pool == address(0) || integrator != address(orchestrator)) return false;

        (,,,,, PoolKey memory poolKey,) = IDopplerHookInitializerView(cfg.poolInitializer()).getState(asset);
        (,, address buybackDst) = IRehypePoolInfoView(cfg.rehypeHookInitializer()).getPoolInfo(poolKey.toId());
        return buybackDst == expectedFeeRouter;
    }

    function _deployWait(QueueEntry storage e) private view returns (uint256) {
        // DeployReady: `waitSeconds` is absolute (`0` = eligible now; resume uses `retryWait`).
        // Queued: `0` means the normal `queueWait` review window.
        if (e.status == QueueStatus.DeployReady) return uint256(e.waitSeconds);
        return e.waitSeconds == 0 ? queueWait : uint256(e.waitSeconds);
    }

    /**
     * @dev Idempotent market deploy (fulfill callback or `deployAssets` resume):
     *      1) FeeRouter via Orchestrator (`FeeRouterFactory.create` returns existing)
     *      2) Airlock.create (skipped when `tokenPredicted` already has Airlock state)
     *      3) PlayerVault + stToken (skipped when `vaultPredicted` already has code)
     *      4) PlayerSetRegistry writes (skipped when already registered / vault attached)
     *      5) ExcessSupplyLocker.allocate (50/50 AT reserve + vested vault stake)
     *
     *      Prerequisites / follow-ups (do not skip when wiring production intake):
     *        - DopplerLocker proxy MUST hold Orchestrator `AUTHORIZED_CONTRACT` so `_exec`
     *          can reach FeeRouterFactory / PlayerVaultFactory / PlayerSetRegistry.
     *        - `DopplerConfig` must be registered and initialized (modules + launch recipe).
     *        - Numeraire is native ETH (`address(0)`). Airlock treats `address(0)` as ETH
     *          (see `Airlock.migrate` / fee collect). Switch to WETH9 only if the recipe
     *          moves to an ERC-20 numeraire.
     *        - Callback gas: full deploy runs inside CvmRouter `maxCallbackGasLimit`.
     */
    function _onDeployReady(QueueEntry storage e) private {
        address pbrFeeHub = tournamentRegistry.pbrFeeHubOf(e.leagueId);
        if (pbrFeeHub == address(0)) revert Errors.HubNotRegistered(e.leagueId);

        // 1) FeeRouter — buyback destination for Rehype fees (idempotent via factory mapping).
        address feeRouter = _deployFeeRouter(e.playerId, pbrFeeHub);

        // 2) Airlock.create — DN404 + bonding pool. Numeraire = native ETH (`address(0)`).
        address asset = _deployBondingMarket(e, feeRouter);

        // 3) PlayerVault + stToken (stToken salt is deterministic; vault salt is vanity-mined).
        (address vault, address stToken) = _deployVault(e, asset);

        // 4) PlayerSet + domestic league vault membership (treasury cache sync).
        _registerPlayerSet(e, asset, feeRouter, vault, stToken);
        _registerLeagueVault(e.leagueId, vault);

        // 5) Split Launchpad excess: 50% AT ringfence + 50% vault stake / vesting.
        _allocateExcess(asset);

        bytes32 playerId = e.playerId;
        emit Events.AssetDeployed(playerId, asset, vault, feeRouter, stToken);
        // Drop from the waiting-room queue (status Deployed is not retained on-disk).
        _removeFromQueue(playerId);
    }

    function _deployFeeRouter(bytes32 playerId, address pbrFeeHub) private returns (address feeRouter) {
        feeRouter = abi.decode(
            _exec(address(feeRouterFactory), abi.encodeCall(FeeRouterFactory.create, (playerId, pbrFeeHub))), (address)
        );
    }

    /**
     * @dev CREATE2 at `tokenPredicted`. Adopt only if this is *our* Airlock market; a foreign
     *      create at the predicted address (salt frontrun) reverts `SaltOccupied` so the caller
     *      re-requests FinalConfig. Otherwise call `Airlock.create`.
     */
    function _deployBondingMarket(QueueEntry storage e, address feeRouter) private returns (address asset) {
        asset = e.tokenPredicted;
        if (asset.code.length != 0) {
            if (_isOurBondingMarket(e.playerId, asset)) return asset;
            revert Errors.SaltOccupied(asset);
        }

        IDopplerConfig cfg = dopplerConfig;
        CreateParams memory params = cfg.buildCreateParams(
            e.name, e.symbol, e.baseURI, feeRouter, e.tokenSalt, address(feeRouterFactory), address(orchestrator)
        );
        (asset,,,,) = Airlock(payable(cfg.airlock())).create(params);
        if (asset != e.tokenPredicted) revert Errors.DeployAddressMismatch(e.tokenPredicted, asset);
    }

    /// @dev CREATE3 at `vaultPredicted`; adopt existing vault/stToken on retry.
    function _deployVault(QueueEntry storage e, address asset) private returns (address vault, address stToken) {
        vault = e.vaultPredicted;
        if (vault.code.length != 0) {
            stToken = PlayerVault(vault).stToken();
            if (PlayerVault(vault).playerToken() != asset || stToken == address(0) || stToken.code.length == 0) {
                revert Errors.DeployAddressMismatch(asset, PlayerVault(vault).playerToken());
            }
            return (vault, stToken);
        }

        address vaultFactory_ = dopplerConfig.vaultFactory();
        bytes32 stTokenSalt =
            PlayerVaultFactory(vaultFactory_).makeSalt(bytes11(keccak256(abi.encodePacked(e.playerId, bytes2("st")))));
        (vault, stToken) = abi.decode(
            _exec(
                vaultFactory_,
                abi.encodeCall(
                    PlayerVaultFactory.create, (e.playerId, asset, e.name, e.symbol, e.vaultSalt, stTokenSalt)
                )
            ),
            (address, address)
        );
        if (vault != e.vaultPredicted) revert Errors.DeployAddressMismatch(e.vaultPredicted, vault);
    }

    /// @dev Skip registry writes that already landed; require addresses match on resume.
    function _registerPlayerSet(
        QueueEntry storage e,
        address asset,
        address feeRouter,
        address vault,
        address stToken
    ) private {
        if (playerSetRegistry.playerExists(e.playerId)) {
            PlayerSet memory set = playerSetRegistry.getPlayerSet(e.playerId);
            if (set.tokenData.token != asset) revert Errors.DeployAddressMismatch(asset, set.tokenData.token);
            if (set.dopplerData.feeRouter != feeRouter) {
                revert Errors.DeployAddressMismatch(feeRouter, set.dopplerData.feeRouter);
            }
            if (set.tournamentData.leagueId != e.leagueId) {
                revert Errors.LeagueMismatch(e.leagueId, set.tournamentData.leagueId);
            }
        } else {
            IDopplerConfig cfg = dopplerConfig;
            PoolKey memory poolKey;
            (,,,,, poolKey,) = IDopplerHookInitializerView(cfg.poolInitializer()).getState(asset);

            // Domestic league id is also the DOMESTIC_LEAGUE tournament id.
            bytes32[] memory activeTournaments = new bytes32[](1);
            activeTournaments[0] = e.leagueId;

            _exec(
                address(playerSetRegistry),
                abi.encodeCall(
                    IPlayerSetRegistry.addPlayerSet,
                    (
                        e.playerId,
                        TokenData({ token: asset, name: e.name, symbol: e.symbol }),
                        TournamentData({ leagueId: e.leagueId, activeTournaments: activeTournaments }),
                        DopplerData({
                            activePool: poolKey,
                            hookDoppler: cfg.rehypeHookInitializer(),
                            hookMigrator: cfg.rehypeHookMigrator(),
                            feeRouter: feeRouter
                        })
                    )
                )
            );
        }

        VaultData memory existingVault = playerSetRegistry.getVaultData(e.playerId);
        if (existingVault.playerVault != address(0)) {
            if (existingVault.playerVault != vault || existingVault.stToken != stToken) {
                revert Errors.DeployAddressMismatch(vault, existingVault.playerVault);
            }
            return;
        }

        _exec(
            address(playerSetRegistry),
            abi.encodeCall(
                IPlayerSetRegistry.addVaultData,
                (e.playerId, VaultData({ playerVault: vault, stToken: stToken, isUtilized: false }))
            )
        );
    }

    /// @dev Idempotent: skip if vault already registered for the domestic league treasury.
    function _registerLeagueVault(bytes32 leagueId, address vault) private {
        if (tournamentRegistry.isVaultRegistered(leagueId, vault)) return;

        address[] memory vaults = new address[](1);
        vaults[0] = vault;
        _exec(address(tournamentRegistry), abi.encodeCall(ITournamentRegistry.registerVaults, (leagueId, vaults)));
    }

    /// @dev Idempotent via `ExcessSupplyLocker.allocate` (no-op once a position exists).
    function _allocateExcess(address asset) private {
        address locker = dopplerConfig.excessSupplyLocker();
        if (locker == address(0)) revert Errors.ZeroAddress();
        _exec(locker, abi.encodeCall(IExcessSupplyLocker.allocate, (asset)));
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
}
