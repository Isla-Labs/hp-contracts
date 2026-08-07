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
        uint256 seasonCount
    );

    event FactoriesConfigured(address pbrTreasuryFactory, address pbrFeeHubFactory);

    /// @notice Deploy module wiring (`DN404Factory`, `PlayerVaultFactory`, Airlock).
    event DeployModulesConfigured(address tokenFactory, address vaultFactory, address airlock);

    /// @notice `queueAssets` result (`added` new ids, `promoted` Ready→Queued, `awaiting` metadata requested).
    event AssetsQueued(
        bytes32 indexed seasonId, uint256 added, uint256 promoted, uint256 awaiting, uint256 pendingTotal
    );

    /// @notice Manual removal during the 24h review window.
    event AssetUnqueued(bytes32 indexed playerId);

    /// @notice CVM `PlayerMetadata` requested for an awaiting season cohort.
    event PlayerMetadataRequested(bytes32 indexed requestId, bytes32 indexed seasonId, uint256 playerCount);

    /// @notice CVM `PlayerMetadata` applied (or failed with `err`).
    event PlayerMetadataFulfilled(bytes32 indexed requestId, bytes32 indexed seasonId, bytes err);

    /// @notice Manual / oracle name-symbol write.
    event PlayerMetadataUpdated(bytes32 indexed playerId, string name, string symbol);

    /// @notice CVM `VanitySalts` requested for a ready queue entry.
    event VanitySaltsRequested(bytes32 indexed requestId, bytes32 indexed playerId, bytes32 tokenInitCodeHash);

    /// @notice Full asset market deployed atomically in the vanity-salts fulfill callback.
    event AssetDeployed(
        bytes32 indexed playerId,
        address indexed token,
        address indexed vault,
        address feeRouter,
        address stToken
    );

    event QueueWaitUpdated(uint256 previous, uint256 queueWait);

    //  DopplerConfig
    event MarketLaunchConfigUpdated(uint256 initialSupply, uint256 numTokensToSell, int24 farTick, uint256 curveCount);
    event BondingCurvesUpdated(uint256 curveCount);
    event GraduationPolicyUpdated(uint256 minGraduateProceeds, uint32 minBondingDuration);
    event FeeDistributionUpdated();

    //  ExcessSupplyLocker
    event ExcessTokenRescued(address indexed token, address indexed to, uint256 amount);
}
