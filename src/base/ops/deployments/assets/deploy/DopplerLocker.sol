// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { Oracle } from "@base/abstract/Oracle.sol";
import { RateLimit } from "@base/abstract/RateLimit.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { MineSalt } from "@base/global/libraries/MineSalt.sol";
import { DeploymentsErrors as Errors } from "@errors/governance/DeploymentsErrors.sol";
import { DeploymentsEvents as Events } from "@events/governance/DeploymentsEvents.sol";
import { IDopplerLocker } from "@interfaces/governance/IDopplerLocker.sol";
import { CvmJob, VanityDeployKind } from "@types/oracle/CvmTypes.sol";
import { AddressProvider } from "@src/AddressProvider.sol";

import { DopplerConfig } from "@deployments/assets/deploy/config/DopplerConfig.sol";

/**
 * @title DopplerLocker
 * @notice Eligibility → metadata → 24h review → vanity salts → bonding-market deploy handoff.
 * @dev Dual CVM jobs via `Oracle._sendOracleRequest(job, args)`:
 *        1) `enqueueEligible` → `CvmJob.PlayerMetadata` (`leagueId`, `playerIds[]`)
 *           — calendar HPID only; no `seasonId` in the worker ABI
 *        2) `deployQueue` (rate-limited) → `CvmJob.VanitySalts` (Asset) once wait elapsed
 *
 *      `_fulfillRequest` dispatches by `requestId → OracleKind`.
 *
 *      Flow:
 *        EligibilityVerifier / owner enqueues `(playerId, leagueId)` pairs
 *        → group by league, request PlayerMetadata
 *        → on fulfill: name/symbol + `queuedAt` (24h review starts)
 *        → owner may `setPlayerMetadata` during review
 *        → anyone calls `deployQueue` after wait; RateLimit gates frequency
 *        → VanitySalts fulfill stores salts and emits `BondingMarketDeployReady`
 *          (Airlock.create + FeeRouter + PlayerVault wire-up is the next slice)
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract DopplerLocker is Initializable, AddressBook, DopplerConfig, Oracle, RateLimit, IDopplerLocker {
    // -------------------------------------------------------------------------
    //  Types
    // -------------------------------------------------------------------------

    enum QueueStatus {
        None,
        /// @dev Enqueued; waiting on / retrying PlayerMetadata.
        AwaitingMetadata,
        /// @dev Metadata set; `queuedAt + queueWait` must elapse before deploy.
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
        bytes32 leagueId;
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
    uint256 public constant DEFAULT_MAX_DEPLOY_BATCH = 5;

    // -------------------------------------------------------------------------
    //  Immutables / config
    // -------------------------------------------------------------------------

    /// @notice Seconds after metadata before `deployQueue` may request vanity salts.
    uint256 public queueWait;

    /// @notice Max vanity-salt requests per `deployQueue` call.
    uint256 public maxDeployBatch;

    /// @notice Enqueue writer (set once); owner may also enqueue.
    address public eligibilityVerifier;

    /// @notice `DN404Factory` (CREATE2 deployer for PlayerToken).
    address public tokenFactory;

    /// @notice `PlayerVaultFactory` (CreateX CREATE3 deployer).
    address public vaultFactory;

    /// @notice Doppler Airlock — `recipient` / `owner` in DN404 ctor (initcode hash).
    address public airlock;

    // -------------------------------------------------------------------------
    //  Queue storage
    // -------------------------------------------------------------------------

    QueueEntry[] private _queue;

    /// @dev `playerId → index + 1` (`0` = not queued).
    mapping(bytes32 playerId => uint256) private _queueIndexPlusOne;

    /// @dev In-flight oracle correlation.
    mapping(bytes32 requestId => OracleKind) private _oracleKind;
    mapping(bytes32 requestId => bytes32) private _oracleLeagueId;
    mapping(bytes32 requestId => bytes32) private _oraclePlayerId;

    // -------------------------------------------------------------------------
    //  Construction
    // -------------------------------------------------------------------------

    /**
     * @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
     * @param deployCooldown_ `deployQueue` rate-limit (immutable on implementation).
     * @dev `CVM_ROUTER` must already be registered on AddressProvider (oracle set first).
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address addressProvider_, uint256 deployCooldown_)
        AddressBook(addressProvider_)
        DopplerConfig()
        Oracle(_cvmRouter(addressProvider_))
        RateLimit(deployCooldown_)
    {
        _disableInitializers();
    }

    /**
     * @notice Proxy init: ownership → Orchestrator, default Doppler config, queue wait.
     * @param queueWait_ Review window (use `DEFAULT_QUEUE_WAIT`).
     * @dev `ORCHESTRATOR` must already be registered on AddressProvider.
     */
    function initialize(uint256 queueWait_) external initializer {
        if (queueWait_ == 0) revert Errors.NotConfigured();
        __DopplerConfig_init(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));
        queueWait = queueWait_;
        maxDeployBatch = DEFAULT_MAX_DEPLOY_BATCH;
    }

    /// @dev Resolve immutable CVM router at impl deploy (AddressBook not yet usable in base ctor list).
    function _cvmRouter(address addressProvider_) private view returns (address router) {
        router = AddressProvider(payable(addressProvider_)).get(keccak256(bytes(Addresses.CVM_ROUTER)));
        if (router == address(0)) revert Errors.ZeroAddress();
    }

    // -------------------------------------------------------------------------
    //  Admin
    // -------------------------------------------------------------------------

    /// @notice One-time wire: EligibilityVerifier may call `enqueueEligible`.
    function setEligibilityVerifier(address eligibilityVerifier_) external onlyOwner {
        if (eligibilityVerifier != address(0)) revert Errors.AlreadySet();
        if (eligibilityVerifier_ == address(0)) revert Errors.ZeroAddress();
        eligibilityVerifier = eligibilityVerifier_;
        emit Events.EligibilityVerifierSet(eligibilityVerifier_);
    }

    /**
     * @notice Wire CREATE2/CREATE3 deployers used when building VanitySalts args.
     * @dev Can be updated by owner if factories are redeployed before markets ship.
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

    function setQueueWait(uint256 queueWait_) external onlyOwner {
        if (queueWait_ == 0) revert Errors.NotConfigured();
        uint256 previous = queueWait;
        queueWait = queueWait_;
        emit Events.QueueWaitUpdated(previous, queueWait_);
    }

    function setMaxDeployBatch(uint256 maxDeployBatch_) external onlyOwner {
        if (maxDeployBatch_ == 0) revert Errors.NotConfigured();
        uint256 previous = maxDeployBatch;
        maxDeployBatch = maxDeployBatch_;
        emit Events.MaxDeployBatchUpdated(previous, maxDeployBatch_);
    }

    /**
     * @notice Manual name/symbol override during the review window (HP backend / ops).
     * @dev Allowed while `Queued` (and re-arms wait from now). Also allowed while
     *      `AwaitingMetadata` to seed metadata without waiting on the oracle.
     */
    function setPlayerMetadata(bytes32 playerId, string calldata name, string calldata symbol) external onlyOwner {
        if (bytes(name).length == 0) revert Errors.EmptyName();
        if (bytes(symbol).length == 0) revert Errors.EmptySymbol();

        QueueEntry storage e = _entry(playerId);
        if (e.status != QueueStatus.Queued && e.status != QueueStatus.AwaitingMetadata) {
            revert Errors.BadQueueStatus(playerId, uint8(e.status));
        }

        e.name = name;
        e.symbol = symbol;
        e.metadataSet = true;
        e.queuedAt = uint64(block.timestamp);
        e.status = QueueStatus.Queued;

        emit Events.PlayerMetadataUpdated(playerId, name, symbol);
    }

    /**
     * @notice Re-request PlayerMetadata for every `AwaitingMetadata` entry in `leagueId`.
     * @dev Useful after an oracle error; owner-gated to avoid spam.
     */
    function retryPlayerMetadata(bytes32 leagueId) external onlyOwner returns (bytes32 requestId) {
        if (leagueId == bytes32(0)) revert Errors.ZeroId();

        bytes32[] memory ids = _collectByLeague(leagueId, QueueStatus.AwaitingMetadata);
        if (ids.length == 0) revert Errors.NothingReady();

        return _requestPlayerMetadata(leagueId, ids);
    }

    // -------------------------------------------------------------------------
    //  Intake
    // -------------------------------------------------------------------------

    /// @inheritdoc IDopplerLocker
    function enqueueEligible(bytes32[] calldata playerIds, bytes32[] calldata leagueIds) external {
        if (msg.sender != owner() && msg.sender != eligibilityVerifier) revert Errors.Unauthorized();
        if (playerIds.length != leagueIds.length) revert Errors.LengthMismatch(playerIds.length, leagueIds.length);

        uint256 added;
        // First pass: insert queue rows.
        uint256 length = playerIds.length;
        for (uint256 i; i < length; ++i) {
            bytes32 playerId = playerIds[i];
            bytes32 leagueId = leagueIds[i];
            if (playerId == bytes32(0) || leagueId == bytes32(0)) continue;
            if (_queueIndexPlusOne[playerId] != 0) continue;

            _queueIndexPlusOne[playerId] = _queue.length + 1;
            _queue.push(
                QueueEntry({
                    playerId: playerId,
                    leagueId: leagueId,
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

        if (added == 0) {
            emit Events.EligiblePlayersEnqueued(0, _queue.length);
            return;
        }

        // Second pass: one PlayerMetadata request per distinct league in this batch.
        _requestMetadataForBatch(playerIds, leagueIds);

        emit Events.EligiblePlayersEnqueued(added, _queue.length);
    }

    // -------------------------------------------------------------------------
    //  Deploy kickoff (public, rate-limited)
    // -------------------------------------------------------------------------

    /**
     * @notice Scan the queue for entries past `queueWait` and request Asset vanity salts.
     * @dev Permissionless. Rate-limited. Requires `configureDeployModules`.
     *      Processes up to `maxDeployBatch` ready players per call.
     */
    function deployQueue() external rateLimited returns (uint256 requested) {
        if (tokenFactory == address(0) || vaultFactory == address(0) || airlock == address(0)) {
            revert Errors.NotConfigured();
        }

        uint256 batchCap = maxDeployBatch;
        uint256 length = _queue.length;
        uint256 wait_ = queueWait;

        for (uint256 i; i < length && requested < batchCap; ++i) {
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

            bytes32 requestId = _sendOracleRequest(CvmJob.VanitySalts, args);
            _oracleKind[requestId] = OracleKind.VanitySalts;
            _oraclePlayerId[requestId] = e.playerId;
            e.status = QueueStatus.AwaitingSalts;

            emit Events.VanitySaltsRequested(requestId, e.playerId, initCodeHash);
            unchecked {
                ++requested;
            }
        }

        if (requested == 0) revert Errors.NothingReady();
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
    //  Internal — metadata
    // -------------------------------------------------------------------------

    function _requestMetadataForBatch(bytes32[] calldata playerIds, bytes32[] calldata leagueIds) private {
        uint256 length = playerIds.length;
        // Track which leagues already requested in this call (small N; O(n²) ok).
        bytes32[] memory seen = new bytes32[](length);
        uint256 seenN;

        for (uint256 i; i < length; ++i) {
            bytes32 leagueId = leagueIds[i];
            bytes32 playerId = playerIds[i];
            if (playerId == bytes32(0) || leagueId == bytes32(0)) continue;
            if (_queueIndexPlusOne[playerId] == 0) continue;

            bool already;
            for (uint256 s; s < seenN; ++s) {
                if (seen[s] == leagueId) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            seen[seenN] = leagueId;
            unchecked {
                ++seenN;
            }

            bytes32[] memory cohort = _collectByLeague(leagueId, QueueStatus.AwaitingMetadata);
            if (cohort.length == 0) continue;
            _requestPlayerMetadata(leagueId, cohort);
        }
    }

    function _requestPlayerMetadata(bytes32 leagueId, bytes32[] memory playerIds)
        private
        returns (bytes32 requestId)
    {
        bytes memory args = abi.encode(leagueId, playerIds);
        requestId = _sendOracleRequest(CvmJob.PlayerMetadata, args);
        _oracleKind[requestId] = OracleKind.PlayerMetadata;
        _oracleLeagueId[requestId] = leagueId;
        emit Events.PlayerMetadataRequested(requestId, leagueId, playerIds.length);
    }

    function _fulfillPlayerMetadata(bytes32 requestId, bytes memory response, bytes memory err) private {
        bytes32 leagueId = _oracleLeagueId[requestId];
        delete _oracleLeagueId[requestId];

        emit Events.PlayerMetadataFulfilled(requestId, leagueId, err);
        if (err.length != 0 || response.length == 0) return;

        (bytes32 respLeague, bytes32[] memory playerIds, string[] memory names, string[] memory symbols) =
            abi.decode(response, (bytes32, bytes32[], string[], string[]));

        if (respLeague != leagueId) return;
        if (playerIds.length != names.length || playerIds.length != symbols.length) return;

        uint256 length = playerIds.length;
        for (uint256 i; i < length; ++i) {
            bytes32 playerId = playerIds[i];
            uint256 idxPlus = _queueIndexPlusOne[playerId];
            if (idxPlus == 0) continue;

            QueueEntry storage e = _queue[idxPlus - 1];
            if (e.leagueId != leagueId) continue;
            if (e.status != QueueStatus.AwaitingMetadata && e.status != QueueStatus.Queued) continue;
            // Skip empty oracle rows; keep awaiting / prior manual metadata.
            if (bytes(names[i]).length == 0 || bytes(symbols[i]).length == 0) continue;

            e.name = names[i];
            e.symbol = symbols[i];
            e.metadataSet = true;
            e.queuedAt = uint64(block.timestamp);
            e.status = QueueStatus.Queued;

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
            // Allow deployQueue to retry after cooldown.
            if (e.status == QueueStatus.AwaitingSalts) e.status = QueueStatus.Queued;
            emit Events.VanitySaltsFulfilled(requestId, playerId, bytes32(0), address(0), bytes32(0), address(0), err);
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
            emit Events.VanitySaltsFulfilled(requestId, playerId, tokenSalt, tokenPredicted, vaultSalt, vaultPredicted, err);
            return;
        }

        e.tokenSalt = tokenSalt;
        e.tokenPredicted = tokenPredicted;
        e.vaultSalt = vaultSalt;
        e.vaultPredicted = vaultPredicted;
        e.status = QueueStatus.DeployReady;

        emit Events.VanitySaltsFulfilled(
            requestId, playerId, tokenSalt, tokenPredicted, vaultSalt, vaultPredicted, err
        );

        _onDeployReady(e);
    }

    /**
     * @dev Handoff after salts arrive. Full Airlock.create + FeeRouter + PlayerVault
     *      sequence lands in a follow-up; for now surface salts for keepers / next slice.
     */
    function _onDeployReady(QueueEntry storage e) private {
        emit Events.BondingMarketDeployReady(
            e.playerId,
            e.leagueId,
            e.name,
            e.symbol,
            e.tokenSalt,
            e.tokenPredicted,
            e.vaultSalt,
            e.vaultPredicted
        );
        // Status stays `DeployReady` until the deploy slice marks `Deployed`.

        // Execute here or execute in the oracle?
    }

    // -------------------------------------------------------------------------
    //  Internal — helpers
    // -------------------------------------------------------------------------

    function _entry(bytes32 playerId) private view returns (QueueEntry storage e) {
        uint256 idxPlus = _queueIndexPlusOne[playerId];
        if (idxPlus == 0) revert Errors.NotQueued(playerId);
        e = _queue[idxPlus - 1];
    }

    function _collectByLeague(bytes32 leagueId, QueueStatus status) private view returns (bytes32[] memory ids) {
        uint256 length = _queue.length;
        uint256 n;
        for (uint256 i; i < length; ++i) {
            QueueEntry storage e = _queue[i];
            if (e.leagueId == leagueId && e.status == status) {
                unchecked {
                    ++n;
                }
            }
        }

        ids = new bytes32[](n);
        uint256 w;
        for (uint256 i; i < length; ++i) {
            QueueEntry storage e = _queue[i];
            if (e.leagueId == leagueId && e.status == status) {
                ids[w] = e.playerId;
                unchecked {
                    ++w;
                }
            }
        }
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
