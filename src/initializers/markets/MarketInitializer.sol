// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { Oracle } from "@base/abstract/Oracle.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { DeploymentsErrors as Errors } from "@errors/initializers/DeploymentsErrors.sol";
import { DeploymentsEvents as Events } from "@events/initializers/DeploymentsEvents.sol";
import { IDopplerConfig } from "@interfaces/governance/IDopplerConfig.sol";
import { IStakeVesting } from "@interfaces/governance/IStakeVesting.sol";
import { IMarketInitializer } from "@interfaces/initializers/IMarketInitializer.sol";
import { IPlayerSetRegistry } from "@interfaces/registries/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@interfaces/registries/ITournamentRegistry.sol";
import { IDopplerHookInitializer } from "@interfaces/markets/IDopplerHookInitializer.sol";
import { IRehypePoolInfo } from "@interfaces/markets/IRehypePoolInfo.sol";
import { MarketOracleKind, MarketQueueEntry, MarketQueueStatus } from "@types/initializers/MarketInitializerTypes.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";
import { DopplerData, PlayerSet, TokenData, TournamentData, VaultData } from "@types/registries/PlayerSetTypes.sol";
import { AddressProvider } from "@src/AddressProvider.sol";
import { FeeRouterFactory } from "@markets/factories/FeeRouterFactory.sol";
import { PlayerVault } from "@vaults/PlayerVault.sol";
import { PlayerVaultFactory } from "@vaults/factories/PlayerVaultFactory.sol";

import { Airlock, CreateParams } from "@doppler/src/Airlock.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

/**
 * @title MarketInitializer
 * @notice Eligibility / ops intake → metadata → lockup → FinalConfig → Airlock market deploy.
 * @dev Replaces `DopplerLocker`. Dual CVM jobs via `Oracle._sendOracleRequest`:
 *        1) `queueAssets` → `CvmJob.PlayerMetadata` (`seasonId`, `playerIds[]`)
 *        2) `deployAssets` (rate-limited) → `CvmJob.FinalConfig` once lockup elapsed
 *
 *      Flow:
 *        TournamentInitializer (DOMESTIC_LEAGUE) → hub live
 *        → Orchestrator `queuePlayers` (MARKET_DEPLOYER) → `queueAssets` → metadata request
 *        → fulfill → `Queued` (`queuedAt = now`; lockup starts)
 *        → Orchestrator may `editMetadata` / `unqueueAsset` during the window
 *        → Orchestrator `processQueue` / anyone `deployAssets` after wait; RateLimit gates frequency
 *        → FinalConfig: oracle pins IPFS metadata + mines salts → fulfill deploys
 *          (FeeRouter → Airlock → Vault → PlayerSet + registerVaults → StakeVesting.allocate)
 *
 *      Access:
 *        - Orchestrator — `queueAssets`, `unqueueAsset`, `editMetadata`, `resetFailedDeploy`
 *        - Timelock — `setQueueWait` / `setRetryWait` / `setMaxDeployAttempts`
 *        - Anyone (rate-limited) — `deployAssets` (also via Orchestrator.processQueue)
 *
 *      Factories / PSR / TR vault membership are called **directly** (no Orchestrator.execute).
 *      Airlock integrator is this contract.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract MarketInitializer is AddressBook, Oracle, IMarketInitializer {
    // --------------------------------------------
    //  Constants
    // --------------------------------------------

    uint256 public constant DEFAULT_QUEUE_WAIT = 24 hours;
    uint256 public constant DEFAULT_RETRY_WAIT = 5 minutes;
    uint256 public constant DEFAULT_MAX_DEPLOY_ATTEMPTS = 5;
    /// @notice Max players per `queueAssets` call and per PlayerMetadata oracle page.
    uint256 public constant METADATA_BATCH_SIZE = 50;

    // --------------------------------------------
    //  Config
    // --------------------------------------------

    /// @notice Seconds after `Queued` before `deployAssets` may request FinalConfig (first attempt).
    uint256 public queueWait;

    /// @notice Seconds after a failed deploy fulfill before `deployAssets` may retry.
    uint256 public retryWait;

    /// @notice Max automatic deploy failures before `DeployFailed` (deployer reset required).
    uint256 public maxDeployAttempts;

    // --------------------------------------------
    //  Queue storage
    // --------------------------------------------

    MarketQueueEntry[] private _queue;

    /// @dev `playerId → index + 1` (`0` = not queued).
    mapping(bytes32 playerId => uint256) private _queueIndexPlusOne;

    /// @dev In-flight oracle correlation.
    mapping(bytes32 requestId => MarketOracleKind) private _oracleKind;
    mapping(bytes32 requestId => bytes32) private _oracleSeasonId;
    mapping(bytes32 requestId => bytes32) private _oraclePlayerId;

    // --------------------------------------------
    //  Access
    // --------------------------------------------

    modifier onlyOrchestrator() {
        if (msg.sender != _getAddress(_addressKey(Addresses.ORCHESTRATOR))) revert Errors.Unauthorized();
        _;
    }

    modifier onlyTimelock() {
        if (msg.sender != _getAddress(_addressKey(Addresses.TIMELOCK))) revert Errors.Unauthorized();
        _;
    }

    modifier onlyOverride() {
        if (msg.sender != _getAddress(_addressKey(Addresses.HP_MULTISIG))) revert Errors.Unauthorized();
        _;
    }

    // --------------------------------------------
    //  Construction
    // --------------------------------------------

    /**
     * @param addressProvider_ Canonical `AddressProvider` (`CVM_ROUTER` must already be registered).
     * @dev Base Sepolia (84532): `queueWait=5m`, `retryWait=1m`, `maxDeployAttempts=3`.
     *      Else: defaults `24h` / `5m` / `5`.
     */
    constructor(address addressProvider_) AddressBook(addressProvider_) Oracle(_cvmRouter(addressProvider_)) {
        if (addressProvider_ == address(0)) revert Errors.ZeroAddress();

        if (block.chainid == 84_532) {
            queueWait = 5 minutes;
            retryWait = 1 minutes;
            maxDeployAttempts = 3;
        } else {
            queueWait = DEFAULT_QUEUE_WAIT;
            retryWait = DEFAULT_RETRY_WAIT;
            maxDeployAttempts = DEFAULT_MAX_DEPLOY_ATTEMPTS;
        }
    }

    function _cvmRouter(address addressProvider_) private view returns (address router) {
        router = AddressProvider(payable(addressProvider_)).get(keccak256(bytes(Addresses.CVM_ROUTER)));
        if (router == address(0)) revert Errors.ZeroAddress();
    }

    // --------------------------------------------
    //  AddressBook resolvers
    // --------------------------------------------

    function _feeRouterFactory() private view returns (FeeRouterFactory) {
        return FeeRouterFactory(_getAddress(_addressKey(Addresses.FEE_ROUTER_FACTORY)));
    }

    function _playerSetRegistry() private view returns (IPlayerSetRegistry) {
        return IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));
    }

    function _tournamentRegistry() private view returns (ITournamentRegistry) {
        return ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }

    function _dopplerConfig() private view returns (IDopplerConfig) {
        return IDopplerConfig(_getAddress(_addressKey(Addresses.DOPPLER_CONFIG)));
    }

    // --------------------------------------------
    //  Admin — waits
    // --------------------------------------------

    function setQueueWait(uint256 queueWait_) external onlyTimelock {
        if (queueWait_ == 0) revert Errors.NotConfigured();
        uint256 previous = queueWait;
        queueWait = queueWait_;
        emit Events.QueueWaitUpdated(previous, queueWait_);
    }

    function setRetryWait(uint256 retryWait_) external onlyTimelock {
        if (retryWait_ == 0) revert Errors.NotConfigured();
        uint256 previous = retryWait;
        retryWait = retryWait_;
        emit Events.RetryWaitUpdated(previous, retryWait_);
    }

    function setMaxDeployAttempts(uint256 maxDeployAttempts_) external onlyTimelock {
        if (maxDeployAttempts_ == 0 || maxDeployAttempts_ > type(uint8).max) revert Errors.NotConfigured();
        uint256 previous = maxDeployAttempts;
        maxDeployAttempts = maxDeployAttempts_;
        emit Events.MaxDeployAttemptsUpdated(previous, maxDeployAttempts_);
    }

    /**
     * @notice Clear `DeployFailed` so ops can redeploy after a bugfix.
     * @param keepSalts If true and salts/URIs remain, resume as `DeployReady` (post-Airlock path).
     *        Otherwise clear salts and return to `Queued` with a short `retryWait` gate.
     */
    function resetFailedDeploy(bytes32 playerId, bool keepSalts) external onlyOverride {
        MarketQueueEntry storage e = _entry(playerId);
        if (e.status != MarketQueueStatus.DeployFailed) revert Errors.BadQueueStatus(playerId, uint8(e.status));

        e.deployAttempts = 0;
        e.queuedAt = uint64(block.timestamp);

        if (
            keepSalts && e.tokenPredicted != address(0) && bytes(e.baseURI).length != 0
                && bytes(e.stakedURI).length != 0
        ) {
            e.status = MarketQueueStatus.DeployReady;
            e.waitSeconds = 0;
        } else {
            e.baseURI = "";
            e.stakedURI = "";
            e.tokenSalt = bytes32(0);
            e.tokenPredicted = address(0);
            e.vaultSalt = bytes32(0);
            e.vaultPredicted = address(0);
            e.status = MarketQueueStatus.Queued;
            e.waitSeconds = uint64(retryWait == 0 ? DEFAULT_RETRY_WAIT : retryWait);
        }
    }

    // --------------------------------------------
    //  Intake / review
    // --------------------------------------------

    /// @inheritdoc IMarketInitializer
    function queueAssets(bytes32 leagueId, bytes32 seasonId, bytes32[] calldata playerIds) external onlyOrchestrator {
        if (leagueId == bytes32(0) || seasonId == bytes32(0)) revert Errors.ZeroId();
        ITournamentRegistry tr = _tournamentRegistry();
        if (!tr.tournamentExists(leagueId)) revert Errors.NotConfigured();
        if (tr.pbrFeeHubOf(leagueId) == address(0)) revert Errors.HubNotRegistered(leagueId);
        bytes32 seasonTournament = tr.tournamentIdOfSeason(seasonId);
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
                MarketQueueEntry({
                    playerId: playerId,
                    leagueId: leagueId,
                    seasonId: seasonId,
                    name: "",
                    symbol: "",
                    baseURI: "",
                    stakedURI: "",
                    metadataSet: false,
                    queuedAt: 0,
                    waitSeconds: 0,
                    status: MarketQueueStatus.AwaitingMetadata,
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

        uint256 awaiting = _requestAwaitingMetadata();
        // `promoted` retained in the event for DopplerLocker compatibility (always 0 — lockup starts on fulfill).
        emit Events.AssetsQueued(leagueId, seasonId, added, 0, awaiting, _queue.length);
    }

    /// @inheritdoc IMarketInitializer
    function unqueueAsset(bytes32 playerId) external onlyOverride {
        MarketQueueEntry storage e = _entry(playerId);
        if (e.status != MarketQueueStatus.Queued && e.status != MarketQueueStatus.DeployFailed) {
            revert Errors.BadQueueStatus(playerId, uint8(e.status));
        }

        _removeFromQueue(playerId);
        emit Events.AssetUnqueued(playerId);
    }

    /// @inheritdoc IMarketInitializer
    function editMetadata(bytes32 playerId, string calldata name, string calldata symbol) external onlyOverride {
        if (bytes(name).length == 0) revert Errors.EmptyName();
        if (bytes(symbol).length == 0) revert Errors.EmptySymbol();

        MarketQueueEntry storage e = _entry(playerId);
        if (e.status != MarketQueueStatus.Queued) revert Errors.BadQueueStatus(playerId, uint8(e.status));

        e.name = name;
        e.symbol = symbol;
        e.baseURI = "";
        e.stakedURI = "";
        e.metadataSet = true;
        e.queuedAt = uint64(block.timestamp);
        e.waitSeconds = 0;

        emit Events.PlayerMetadataUpdated(playerId, name, symbol, e.baseURI);
    }

    // --------------------------------------------
    //  Deploy kickoff (public, rate-limited)
    // --------------------------------------------

    /// @inheritdoc IMarketInitializer
    function deployAssets() external onlyOrchestrator returns (bytes32 requestId) {
        IDopplerConfig cfg = _dopplerConfig();
        if (cfg.tokenFactory() == address(0) || cfg.vaultFactory() == address(0) || cfg.airlock() == address(0)) {
            revert Errors.NotConfigured();
        }

        uint256 length = _queue.length;

        for (uint256 i; i < length; ++i) {
            MarketQueueEntry storage e = _queue[i];
            if (e.status != MarketQueueStatus.DeployReady) continue;
            if (e.tokenPredicted == address(0) || bytes(e.baseURI).length == 0 || bytes(e.stakedURI).length == 0) {
                continue;
            }
            if (block.timestamp < uint256(e.queuedAt) + _deployWait(e)) continue;

            try this.executeDeploy(e.playerId) { }
            catch {
                _handleDeployFailure(e);
            }
            return bytes32(0);
        }

        for (uint256 i; i < length; ++i) {
            MarketQueueEntry storage e = _queue[i];
            if (e.status != MarketQueueStatus.Queued) continue;
            if (!e.metadataSet) continue;
            if (block.timestamp < uint256(e.queuedAt) + _deployWait(e)) continue;

            bytes memory args = abi.encode(
                e.playerId,
                cfg.tokenFactory(),
                cfg.vaultFactory(),
                cfg.airlock(),
                cfg.initialSupply(),
                cfg.dn404Unit(),
                e.name,
                e.symbol
            );

            requestId = _sendOracleRequest(CvmJob.FinalConfig, args);
            _oracleKind[requestId] = MarketOracleKind.Deploy;
            _oraclePlayerId[requestId] = e.playerId;
            e.status = MarketQueueStatus.AwaitingFinalConfig;

            emit Events.FinalConfigRequested(requestId, e.playerId);
            return requestId;
        }

        revert Errors.NothingReady();
    }

    // --------------------------------------------
    //  Oracle callback
    // --------------------------------------------

    /// @inheritdoc Oracle
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        MarketOracleKind kind = _oracleKind[requestId];
        if (kind == MarketOracleKind.None) revert Errors.UnknownOracleRequest(requestId);

        delete _oracleKind[requestId];

        if (kind == MarketOracleKind.PlayerMetadata) {
            _fulfillPlayerMetadata(requestId, response, err);
        } else {
            _fulfillDeploy(requestId, response, err);
        }
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function queueCount() external view returns (uint256) {
        return _queue.length;
    }

    function isQueued(bytes32 playerId) external view returns (bool) {
        return _queueIndexPlusOne[playerId] != 0;
    }

    function queueEntry(bytes32 playerId) external view returns (MarketQueueEntry memory) {
        return _entry(playerId);
    }

    function queueAt(uint256 index) external view returns (MarketQueueEntry memory) {
        return _queue[index];
    }

    /// @notice Earliest timestamp when `playerId` becomes deploy-eligible (`0` if unknown).
    function deployUnlockAt(bytes32 playerId) external view returns (uint256) {
        MarketQueueEntry storage e = _entry(playerId);
        if (e.queuedAt == 0) return 0;
        if (e.status != MarketQueueStatus.Queued && e.status != MarketQueueStatus.DeployReady) return 0;
        return uint256(e.queuedAt) + _deployWait(e);
    }

    // --------------------------------------------
    //  Internal — intake
    // --------------------------------------------

    /**
     * @dev PlayerMetadata requests for `AwaitingMetadata` rows, grouped by `seasonId`
     *      and paginated to `METADATA_BATCH_SIZE` playerIds per request.
     */
    function _requestAwaitingMetadata() private returns (uint256 awaiting) {
        uint256 length = _queue.length;
        bytes32[] memory seen = new bytes32[](length);
        uint256 seenN;

        for (uint256 i; i < length; ++i) {
            MarketQueueEntry storage e = _queue[i];
            if (e.status != MarketQueueStatus.AwaitingMetadata) continue;

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

            bytes32[] memory ids = _collectBySeason(e.seasonId, MarketQueueStatus.AwaitingMetadata);
            if (ids.length == 0) continue;

            unchecked {
                awaiting += ids.length;
            }
            _sendMetadataPages(e.seasonId, ids);
        }
    }

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
            _oracleKind[requestId] = MarketOracleKind.PlayerMetadata;
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

        uint64 now_ = uint64(block.timestamp);
        uint256 length = playerIds.length;
        for (uint256 i; i < length; ++i) {
            bytes32 playerId = playerIds[i];
            uint256 idxPlus = _queueIndexPlusOne[playerId];
            if (idxPlus == 0) continue;

            MarketQueueEntry storage e = _queue[idxPlus - 1];
            if (e.seasonId != seasonId) continue;
            if (e.status != MarketQueueStatus.AwaitingMetadata) continue;
            if (bytes(names[i]).length == 0 || bytes(symbols[i]).length == 0) continue;

            e.name = names[i];
            e.symbol = symbols[i];
            e.baseURI = "";
            e.stakedURI = "";
            e.metadataSet = true;
            e.status = MarketQueueStatus.Queued;
            e.queuedAt = now_;
            e.waitSeconds = 0;

            emit Events.PlayerMetadataUpdated(playerId, names[i], symbols[i], e.baseURI);
        }
    }

    // --------------------------------------------
    //  Internal — deploy fulfill
    // --------------------------------------------

    function _fulfillDeploy(bytes32 requestId, bytes memory response, bytes memory err) private {
        bytes32 playerId = _oraclePlayerId[requestId];
        delete _oraclePlayerId[requestId];

        MarketQueueEntry storage e = _entry(playerId);
        if (e.status != MarketQueueStatus.AwaitingFinalConfig) return;

        if (err.length != 0 || response.length == 0) {
            _requeueForFinalConfig(e);
            return;
        }

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
     * @notice Validate FinalConfig response and persist salts/URIs as `DeployReady`.
     * @dev External so `_fulfillDeploy` can `try/catch` without reverting the CVM callback.
     */
    function applyFinalConfig(bytes32 playerId, bytes calldata response) external {
        if (msg.sender != address(this)) revert Errors.Unauthorized();

        MarketQueueEntry storage e = _entry(playerId);
        if (e.status != MarketQueueStatus.AwaitingFinalConfig) {
            revert Errors.BadQueueStatus(playerId, uint8(e.status));
        }

        (
            bytes32 tokenSalt,
            address tokenPredicted,
            bytes32 vaultSalt,
            address vaultPredicted,
            string memory baseURI_,
            string memory stakedURI_
        ) = abi.decode(response, (bytes32, address, bytes32, address, string, string));

        if (
            tokenSalt == bytes32(0) || vaultSalt == bytes32(0) || tokenPredicted == address(0)
                || vaultPredicted == address(0) || bytes(baseURI_).length == 0 || bytes(stakedURI_).length == 0
        ) {
            revert Errors.NotConfigured();
        }

        e.baseURI = baseURI_;
        e.stakedURI = stakedURI_;
        e.tokenSalt = tokenSalt;
        e.tokenPredicted = tokenPredicted;
        e.vaultSalt = vaultSalt;
        e.vaultPredicted = vaultPredicted;
        e.status = MarketQueueStatus.DeployReady;
        e.queuedAt = uint64(block.timestamp);
        e.waitSeconds = 0;
    }

    /**
     * @notice Run idempotent FeeRouter → Airlock → vault → registry deploy for a `DeployReady` entry.
     * @dev External so fulfill / `deployAssets` can `try/catch` without reverting the caller.
     */
    function executeDeploy(bytes32 playerId) external {
        if (msg.sender != address(this)) revert Errors.Unauthorized();

        MarketQueueEntry storage e = _entry(playerId);
        if (e.status != MarketQueueStatus.DeployReady) revert Errors.BadQueueStatus(playerId, uint8(e.status));
        _onDeployReady(e);
    }

    function _requeueForFinalConfig(MarketQueueEntry storage e) private {
        bool exhausted = _noteDeployFailure(e);

        e.baseURI = "";
        e.stakedURI = "";
        e.tokenSalt = bytes32(0);
        e.tokenPredicted = address(0);
        e.vaultSalt = bytes32(0);
        e.vaultPredicted = address(0);

        if (exhausted) return;

        uint256 wait_ = retryWait == 0 ? DEFAULT_RETRY_WAIT : retryWait;
        e.status = MarketQueueStatus.Queued;
        e.queuedAt = uint64(block.timestamp);
        e.waitSeconds = uint64(wait_);
        emit Events.DeployRetryQueued(e.playerId, e.queuedAt, wait_, e.deployAttempts, uint8(_maxDeployAttempts()));
    }

    function _handleDeployFailure(MarketQueueEntry storage e) private {
        if (_isOurBondingMarket(e.playerId, e.tokenPredicted)) {
            _scheduleDeployResume(e);
        } else {
            _requeueForFinalConfig(e);
        }
    }

    function _scheduleDeployResume(MarketQueueEntry storage e) private {
        if (_noteDeployFailure(e)) return;

        uint256 wait_ = retryWait == 0 ? DEFAULT_RETRY_WAIT : retryWait;
        e.status = MarketQueueStatus.DeployReady;
        e.queuedAt = uint64(block.timestamp);
        e.waitSeconds = uint64(wait_);
        emit Events.DeployRetryQueued(e.playerId, e.queuedAt, wait_, e.deployAttempts, uint8(_maxDeployAttempts()));
    }

    function _noteDeployFailure(MarketQueueEntry storage e) private returns (bool exhausted) {
        uint8 next = e.deployAttempts + 1;
        e.deployAttempts = next;
        uint256 max_ = _maxDeployAttempts();
        if (next >= max_) {
            e.status = MarketQueueStatus.DeployFailed;
            emit Events.DeployAttemptsExhausted(e.playerId, next);
            return true;
        }
        return false;
    }

    function _maxDeployAttempts() private view returns (uint256) {
        return maxDeployAttempts == 0 ? DEFAULT_MAX_DEPLOY_ATTEMPTS : maxDeployAttempts;
    }

    /**
     * @dev True when `asset` is our Airlock market: this contract is integrator **and** Rehype
     *      `buybackDst` equals the FeeRouter from AddressBook `FEE_ROUTER_FACTORY` for `playerId`.
     */
    function _isOurBondingMarket(bytes32 playerId, address asset) private view returns (bool) {
        address expectedFeeRouter = _feeRouterFactory().feeRouterOf(playerId);
        if (asset == address(0) || asset.code.length == 0 || expectedFeeRouter == address(0)) return false;

        IDopplerConfig cfg = _dopplerConfig();
        (,,,,, address pool,,,, address integrator) = Airlock(payable(cfg.airlock())).getAssetData(asset);
        if (pool == address(0) || integrator != address(this)) return false;

        (,,,,, PoolKey memory poolKey,) = IDopplerHookInitializer(cfg.poolInitializer()).getState(asset);
        (,, address buybackDst) = IRehypePoolInfo(cfg.rehypeHookInitializer()).getPoolInfo(poolKey.toId());
        return buybackDst == expectedFeeRouter;
    }

    function _deployWait(MarketQueueEntry storage e) private view returns (uint256) {
        if (e.status == MarketQueueStatus.DeployReady) return uint256(e.waitSeconds);
        return e.waitSeconds == 0 ? queueWait : uint256(e.waitSeconds);
    }

    /**
     * @dev Idempotent market deploy (fulfill callback or `deployAssets` resume):
     *      1) FeeRouter (idempotent via factory mapping)
     *      2) Airlock.create (skipped when `tokenPredicted` already has our market)
     *      3) PlayerVault + stToken (skipped when `vaultPredicted` already has code)
     *      4) PlayerSet + domestic league vault membership
     *      5) StakeVesting.allocate
     */
    function _onDeployReady(MarketQueueEntry storage e) private {
        address pbrFeeHub = _tournamentRegistry().pbrFeeHubOf(e.leagueId);
        if (pbrFeeHub == address(0)) revert Errors.HubNotRegistered(e.leagueId);

        address feeRouter = _deployFeeRouter(e.playerId, pbrFeeHub);
        address asset = _deployBondingMarket(e, feeRouter);
        (address vault, address stToken) = _deployVault(e, asset);

        _registerPlayerSet(e, asset, feeRouter, vault, stToken);
        _registerLeagueVault(e.leagueId, vault);
        _allocateExcess(asset);

        bytes32 playerId = e.playerId;
        emit Events.AssetDeployed(playerId, asset, vault, feeRouter, stToken);
        _removeFromQueue(playerId);
    }

    function _deployFeeRouter(bytes32 playerId, address pbrFeeHub) private returns (address feeRouter) {
        feeRouter = _feeRouterFactory().create(playerId, pbrFeeHub);
    }

    function _deployBondingMarket(MarketQueueEntry storage e, address feeRouter) private returns (address asset) {
        asset = e.tokenPredicted;
        if (asset.code.length != 0) {
            if (_isOurBondingMarket(e.playerId, asset)) return asset;
            revert Errors.SaltOccupied(asset);
        }

        IDopplerConfig cfg = _dopplerConfig();
        CreateParams memory params = cfg.buildCreateParams(
            e.name,
            e.symbol,
            e.baseURI,
            feeRouter,
            e.tokenSalt,
            address(_feeRouterFactory()),
            address(this) // Airlock integrator — this contract owns the deploy path
        );
        (asset,,,,) = Airlock(payable(cfg.airlock())).create(params);
        if (asset != e.tokenPredicted) revert Errors.DeployAddressMismatch(e.tokenPredicted, asset);
    }

    function _deployVault(MarketQueueEntry storage e, address asset) private returns (address vault, address stToken) {
        vault = e.vaultPredicted;
        if (vault.code.length != 0) {
            stToken = PlayerVault(vault).stToken();
            if (PlayerVault(vault).playerToken() != asset || stToken == address(0) || stToken.code.length == 0) {
                revert Errors.DeployAddressMismatch(asset, PlayerVault(vault).playerToken());
            }
            return (vault, stToken);
        }

        address vaultFactory_ = _dopplerConfig().vaultFactory();
        bytes11 stEntropy = bytes11(keccak256(abi.encodePacked(e.playerId, bytes2("st"))));
        bytes32 stTokenSalt = bytes32(uint256(uint160(vaultFactory_))) << 96 | bytes32(uint256(uint88(stEntropy)));
        (vault, stToken) = PlayerVaultFactory(vaultFactory_)
            .create(e.playerId, asset, e.name, e.symbol, e.vaultSalt, stTokenSalt, e.stakedURI);
        if (vault != e.vaultPredicted) revert Errors.DeployAddressMismatch(e.vaultPredicted, vault);
    }

    function _registerPlayerSet(
        MarketQueueEntry storage e,
        address asset,
        address feeRouter,
        address vault,
        address stToken
    ) private {
        IPlayerSetRegistry psr = _playerSetRegistry();
        if (psr.playerExists(e.playerId)) {
            PlayerSet memory set = psr.getPlayerSet(e.playerId);
            if (set.tokenData.token != asset) revert Errors.DeployAddressMismatch(asset, set.tokenData.token);
            if (set.dopplerData.feeRouter != feeRouter) {
                revert Errors.DeployAddressMismatch(feeRouter, set.dopplerData.feeRouter);
            }
            if (set.tournamentData.leagueId != e.leagueId) {
                revert Errors.LeagueMismatch(e.leagueId, set.tournamentData.leagueId);
            }
            if (set.vaultData.playerVault != vault || set.vaultData.stToken != stToken) {
                revert Errors.DeployAddressMismatch(vault, set.vaultData.playerVault);
            }
            return;
        }

        IDopplerConfig cfg = _dopplerConfig();
        PoolKey memory poolKey;
        (,,,,, poolKey,) = IDopplerHookInitializer(cfg.poolInitializer()).getState(asset);

        bytes32[] memory activeTournaments = new bytes32[](1);
        activeTournaments[0] = e.leagueId;

        psr.addPlayerSet(
            e.playerId,
            TokenData({ token: asset, name: e.name, symbol: e.symbol }),
            TournamentData({ leagueId: e.leagueId, activeTournaments: activeTournaments }),
            DopplerData({
                activePool: poolKey,
                // PoolKey.hooks are Doppler initializer / migrator — not Rehype satellites.
                hookDoppler: cfg.poolInitializer(),
                hookMigrator: cfg.liquidityMigrator(),
                feeRouter: feeRouter
            }),
            VaultData({ playerVault: vault, stToken: stToken, isUtilized: false })
        );
    }

    function _registerLeagueVault(bytes32 leagueId, address vault) private {
        ITournamentRegistry tr = _tournamentRegistry();
        if (tr.isVaultRegistered(leagueId, vault)) return;

        address[] memory vaults = new address[](1);
        vaults[0] = vault;
        tr.registerVaults(leagueId, vaults);
    }

    function _allocateExcess(address asset) private {
        address vesting = _dopplerConfig().stakeVesting();
        if (vesting == address(0)) revert Errors.ZeroAddress();
        IStakeVesting(vesting).allocate(asset);
    }

    // --------------------------------------------
    //  Internal — helpers
    // --------------------------------------------

    function _entry(bytes32 playerId) private view returns (MarketQueueEntry storage e) {
        uint256 idxPlus = _queueIndexPlusOne[playerId];
        if (idxPlus == 0) revert Errors.NotQueued(playerId);
        e = _queue[idxPlus - 1];
    }

    function _collectBySeason(bytes32 seasonId, MarketQueueStatus status) private view returns (bytes32[] memory ids) {
        uint256 length = _queue.length;
        uint256 n;
        for (uint256 i; i < length; ++i) {
            MarketQueueEntry storage e = _queue[i];
            if (e.seasonId == seasonId && e.status == status) {
                unchecked {
                    ++n;
                }
            }
        }

        ids = new bytes32[](n);
        uint256 w;
        for (uint256 i; i < length; ++i) {
            MarketQueueEntry storage e = _queue[i];
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
            MarketQueueEntry storage moved = _queue[last];
            _queue[index] = moved;
            _queueIndexPlusOne[moved.playerId] = index + 1;
        }

        _queue.pop();
        delete _queueIndexPlusOne[playerId];
    }
}
