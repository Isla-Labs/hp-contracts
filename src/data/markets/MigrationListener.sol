// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { Oracle } from "@base/abstract/Oracle.sol";
import { RateLimit } from "@base/abstract/RateLimit.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { MigrationErrors as Errors } from "@errors/data/MigrationErrors.sol";
import { MigrationEvents as Events } from "@events/data/MigrationEvents.sol";
import { IMigrationListener } from "@interfaces/data/IMigrationListener.sol";
import { IDopplerConfig } from "@interfaces/governance/IDopplerConfig.sol";
import { IPlayerSetRegistry } from "@interfaces/registries/IPlayerSetRegistry.sol";
import { IAirlock } from "@interfaces/markets/IAirlock.sol";
import { IDopplerHookInitializer } from "@interfaces/markets/IDopplerHookInitializer.sol";
import { IDopplerHookMigrator } from "@interfaces/markets/IDopplerHookMigrator.sol";
import { AddressProvider } from "@src/AddressProvider.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";
import { PlayerSet, PlayerStatus } from "@types/registries/PlayerSetTypes.sol";

/**
 * @title MigrationListener
 * @notice Syncs BONDING player markets to GRADUATED after Doppler Airlock migration.
 * @dev Dual path:
 *        1) `scanMigrations` (rate-limited, default 1m) → `CvmJob.BondingMigrationScan` → fulfill
 *        2) `syncMigrations` (max 10 tokens, no rate limit) — keeper / UI batch
 *
 *      Shared apply (`_syncToken`):
 *        - Skip unless PSR status is BONDING
 *        - If bonding pool still `Initialized`, `try Airlock.migrate` (race-safe)
 *        - When initializer status is `Exited`, read spot `PoolKey` from migrator → `graduatePool`
 *
 *      `PlayerSetRegistry.graduatePool` is MigrationListener-only (direct write).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract MigrationListener is AddressBook, Oracle, RateLimit, IMigrationListener {
    // --------------------------------------------
    //  Constants
    // --------------------------------------------

    uint256 public constant DEFAULT_SCAN_COOLDOWN = 1 minutes;
    uint256 public constant MAX_DIRECT_BATCH = 10;
    /// @dev Soft cap mirrored by the CVM job (callback gas).
    uint256 public constant MAX_ORACLE_UPDATES = 25;

    /// @dev `DopplerHookInitializer.PoolStatus` ordinals.
    uint8 private constant STATUS_INITIALIZED = 1;
    uint8 private constant STATUS_EXITED = 4;

    // --------------------------------------------
    //  Construction
    // --------------------------------------------

    /**
     * @param addressProvider_ Canonical `AddressProvider` (`CVM_ROUTER` must already be registered).
     * @param scanCooldown_ Min seconds between `scanMigrations` kicks (`0` → 1 minute).
     */
    constructor(
        address addressProvider_,
        uint256 scanCooldown_
    )
        AddressBook(addressProvider_)
        Oracle(_cvmRouter(addressProvider_))
        RateLimit(scanCooldown_ == 0 ? DEFAULT_SCAN_COOLDOWN : scanCooldown_)
    {
        if (addressProvider_ == address(0)) revert Errors.ZeroAddress();
    }

    function _cvmRouter(address addressProvider_) private view returns (address router) {
        router = AddressProvider(payable(addressProvider_)).get(keccak256(bytes(Addresses.CVM_ROUTER)));
        if (router == address(0)) revert Errors.ZeroAddress();
    }

    // --------------------------------------------
    //  AddressBook resolvers
    // --------------------------------------------

    function _playerSetRegistry() private view returns (IPlayerSetRegistry) {
        return IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));
    }

    function _dopplerConfig() private view returns (IDopplerConfig) {
        return IDopplerConfig(_getAddress(_addressKey(Addresses.DOPPLER_CONFIG)));
    }

    // --------------------------------------------
    //  Public entry
    // --------------------------------------------

    /// @inheritdoc IMigrationListener
    function scanMigrations() external rateLimited returns (bytes32 requestId) {
        requestId = _sendOracleRequest(CvmJob.BondingMigrationScan, "");
        emit Events.MigrationScanRequested(requestId);
    }

    /// @inheritdoc IMigrationListener
    function syncMigrations(address[] calldata tokens) external {
        uint256 length = tokens.length;
        if (length == 0) revert Errors.EmptyBatch();
        if (length > MAX_DIRECT_BATCH) revert Errors.BatchTooLarge(length, MAX_DIRECT_BATCH);

        for (uint256 i; i < length; ++i) {
            _syncToken(tokens[i]);
        }
    }

    // --------------------------------------------
    //  Oracle callback
    // --------------------------------------------

    /// @inheritdoc Oracle
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        if (err.length != 0) {
            emit Events.MigrationScanFulfilled(requestId, 0, err);
            return;
        }

        address[] memory tokens = abi.decode(response, (address[]));
        uint256 length = tokens.length;
        if (length > MAX_ORACLE_UPDATES) length = MAX_ORACLE_UPDATES;

        emit Events.MigrationScanFulfilled(requestId, length, err);

        for (uint256 i; i < length; ++i) {
            _syncToken(tokens[i]);
        }
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    /**
     * @dev Best-effort per-token sync. Never reverts the outer batch/fulfill on Doppler races.
     */
    function _syncToken(address token) private {
        if (token == address(0)) {
            emit Events.MigrationSkipped(token, bytes("zero"));
            return;
        }

        IPlayerSetRegistry psr = _playerSetRegistry();
        bytes32 playerId = psr.playerIdOfToken(token);
        if (playerId == bytes32(0)) {
            emit Events.MigrationSkipped(token, bytes("unknown"));
            return;
        }

        PlayerSet memory set = psr.getPlayerSet(playerId);
        if (set.status != PlayerStatus.BONDING) {
            emit Events.MigrationSkipped(token, bytes("not-bonding"));
            return;
        }

        IDopplerConfig cfg = _dopplerConfig();
        address poolInitializer = cfg.poolInitializer();
        address airlock = cfg.airlock();
        address liquidityMigrator = cfg.liquidityMigrator();
        if (poolInitializer == address(0) || airlock == address(0) || liquidityMigrator == address(0)) {
            emit Events.MigrationSkipped(token, bytes("not-configured"));
            return;
        }

        (,,,, uint8 status,,) = IDopplerHookInitializer(poolInitializer).getState(token);

        if (status == STATUS_INITIALIZED) {
            // Race: may graduate between CVM scan / batch check and this call.
            try IAirlock(airlock).migrate(token) { }
            catch (bytes memory reason) {
                emit Events.MigrationSkipped(token, reason.length == 0 ? bytes("migrate-revert") : reason);
            }
            (,,,, status,,) = IDopplerHookInitializer(poolInitializer).getState(token);
        }

        if (status != STATUS_EXITED) {
            if (status != STATUS_INITIALIZED) {
                emit Events.MigrationSkipped(token, bytes("not-exited"));
            }
            return;
        }

        (address token0, address token1) = IDopplerHookMigrator(liquidityMigrator).getPair(token);
        if (token0 == address(0) && token1 == address(0)) {
            emit Events.MigrationSkipped(token, bytes("no-pair"));
            return;
        }

        (, PoolKey memory spotPool,,,,,,) = IDopplerHookMigrator(liquidityMigrator).getAssetData(token0, token1);
        if (address(spotPool.hooks) == address(0)) {
            emit Events.MigrationSkipped(token, bytes("no-spot-pool"));
            return;
        }

        // graduatePool reverts on hook mismatch — catch so one bad entry cannot brick a batch.
        try psr.graduatePool(playerId, spotPool) {
            emit Events.MigrationSynced(playerId, token, address(spotPool.hooks));
        } catch (bytes memory reason) {
            emit Events.MigrationSkipped(token, reason.length == 0 ? bytes("graduate-revert") : reason);
        }
    }
}
