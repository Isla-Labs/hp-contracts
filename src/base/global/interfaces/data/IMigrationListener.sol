// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IMigrationListener
 * @notice Bonding → spot graduation sync for player markets.
 * @dev Two paths:
 *        1) `scanMigrations` — rate-limited CVM scan of all BONDING markets; fulfill applies sync
 *        2) `syncMigrations` — direct batch (max 10 tokens), no rate limit; onchain re-check + try/catch
 */
interface IMigrationListener {
    /**
     * @notice Kick a CVM scan of BONDING markets that need migrate / graduate catch-up.
     * @dev Rate-limited (default 1 minute). Permissionless.
     * @return requestId Pending `CvmJob.BondingMigrationScan` id.
     */
    function scanMigrations() external returns (bytes32 requestId);

    /**
     * @notice Sync a small batch of player tokens (max 10) without the scan rate limit.
     * @dev Re-checks Doppler state; `Airlock.migrate` is try/caught for races. Permissionless.
     */
    function syncMigrations(address[] calldata tokens) external;
}
