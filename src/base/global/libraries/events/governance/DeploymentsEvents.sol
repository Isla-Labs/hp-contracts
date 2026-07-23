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

    event EligibilityVerifierSet(address indexed eligibilityVerifier);

    /// @notice Waiting-room intake from EligibilityVerifier (`added` new ids this call).
    event EligiblePlayersEnqueued(uint256 added, uint256 pendingTotal);

    //  DopplerConfig
    event MarketLaunchConfigUpdated(uint256 initialSupply, uint256 numTokensToSell, int24 farTick, uint256 curveCount);
    event BondingCurvesUpdated(uint256 curveCount);
    event GraduationPolicyUpdated(uint256 minGraduateProceeds, uint32 minBondingDuration);
    event FeeDistributionUpdated();
}
