// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title MarketInitializerTypes
 * @notice Waiting-room + oracle correlation types for `MarketInitializer`.
 */

/// @notice Deploy queue phase for one pending market.
enum MarketQueueStatus {
    None,
    /// @dev Intake; waiting on PlayerMetadata.
    AwaitingMetadata,
    /// @dev Metadata set; lockup clock running (`queuedAt + active wait`).
    Queued,
    /// @dev FinalConfig request in flight.
    AwaitingFinalConfig,
    /// @dev Salts/`baseURI` stored; deploy in progress or waiting to resume after a partial failure.
    DeployReady,
    Deployed,
    /// @dev Automatic retries exhausted; deployer must `resetFailedDeploy`.
    DeployFailed
}

/// @notice Discriminator for in-flight MarketInitializer CVM jobs.
enum MarketOracleKind {
    None,
    PlayerMetadata,
    /// @dev FinalConfig fulfill → store salts/URIs → `_onDeployReady`.
    Deploy
}

/**
 * @notice One MarketInitializer waiting-room entry.
 * @dev Mirrors TransferLocker `PendingLifecycle` for the deploy path.
 */
struct MarketQueueEntry {
    bytes32 playerId;
    /// @dev Domestic league id (`==` tournamentId for DOMESTIC_LEAGUE).
    bytes32 leagueId;
    /// @dev Tournament-calendar HPID (`tmcl` after HPID decode).
    bytes32 seasonId;
    string name;
    string symbol;
    /// @dev DN404 metadata prefix from FinalConfig (`ipfs://…/`); empty until fulfill.
    string baseURI;
    /// @dev StakedToken ERC-7572 `contractURI` from FinalConfig (`ipfs://…`); empty until fulfill.
    string stakedURI;
    bool metadataSet;
    uint64 queuedAt;
    /// @dev Per-entry wait override (`0` → use `queueWait`; set to `retryWait` on deploy fail).
    uint64 waitSeconds;
    MarketQueueStatus status;
    bytes32 tokenSalt;
    address tokenPredicted;
    bytes32 vaultSalt;
    address vaultPredicted;
    /// @dev Failed deploy attempts toward `maxDeployAttempts` (oracle + onchain).
    uint8 deployAttempts;
}
