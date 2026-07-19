// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { TournamentType } from "@base/global/types/TournamentTypes.sol";

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
}
