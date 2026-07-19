// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library DeploymentsEvents {
    event DomesticLeagueDeployed(
        bytes32 indexed tournamentId,
        address indexed pbrTreasury,
        address indexed pbrFeeHub,
        uint16 initialSeason,
        uint256 registeredPlayers
    );

    event FactoriesConfigured(address pbrTreasuryFactory, address pbrFeeHubFactory);
}
