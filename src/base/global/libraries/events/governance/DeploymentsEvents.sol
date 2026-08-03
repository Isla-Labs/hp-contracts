// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { TournamentType } from "@types/TournamentTypes.sol";

library DeploymentsEvents {
    event TournamentDeployed(
        bytes32 indexed tournamentId,
        TournamentType tournamentType,
        address indexed pbrTreasury,
        uint16 initialSeason,
        uint256 hubCount,
        uint256 registeredPlayers
    );

    event FactoriesConfigured(address pbrTreasuryFactory, address pbrFeeHubFactory);

    /// @notice Enqueue writer (`EligibilityVerifier`).
    event EligibilityVerifierSet(address indexed eligibilityVerifier);

    /// @notice Deploy module wiring (`DN404Factory`, `PlayerVaultFactory`, Airlock).
    event DeployModulesConfigured(address tokenFactory, address vaultFactory, address airlock);

    /// @notice Waiting-room intake (`added` new ids this call).
    event EligiblePlayersEnqueued(uint256 added, uint256 pendingTotal);

    /// @notice CVM `PlayerMetadata` requested for a league cohort.
    event PlayerMetadataRequested(bytes32 indexed requestId, bytes32 indexed leagueId, uint256 playerCount);

    /// @notice CVM `PlayerMetadata` applied (or failed with `err`).
    event PlayerMetadataFulfilled(bytes32 indexed requestId, bytes32 indexed leagueId, bytes err);

    /// @notice Manual / oracle name-symbol write during review window.
    event PlayerMetadataUpdated(bytes32 indexed playerId, string name, string symbol);

    /// @notice CVM `VanitySalts` requested for a ready queue entry.
    event VanitySaltsRequested(bytes32 indexed requestId, bytes32 indexed playerId, bytes32 tokenInitCodeHash);

    /// @notice CVM `VanitySalts` applied (or failed with `err`).
    event VanitySaltsFulfilled(
        bytes32 indexed requestId,
        bytes32 indexed playerId,
        bytes32 tokenSalt,
        address tokenPredicted,
        bytes32 vaultSalt,
        address vaultPredicted,
        bytes err
    );

    /// @notice Salts stored; bonding-market deploy handoff (Airlock path lands next).
    event BondingMarketDeployReady(
        bytes32 indexed playerId,
        bytes32 indexed leagueId,
        string name,
        string symbol,
        bytes32 tokenSalt,
        address tokenPredicted,
        bytes32 vaultSalt,
        address vaultPredicted
    );

    event QueueWaitUpdated(uint256 previous, uint256 queueWait);
    event MaxDeployBatchUpdated(uint256 previous, uint256 maxDeployBatch);

    //  DopplerConfig
    event MarketLaunchConfigUpdated(uint256 initialSupply, uint256 numTokensToSell, int24 farTick, uint256 curveCount);
    event BondingCurvesUpdated(uint256 curveCount);
    event GraduationPolicyUpdated(uint256 minGraduateProceeds, uint32 minBondingDuration);
    event FeeDistributionUpdated();
}
