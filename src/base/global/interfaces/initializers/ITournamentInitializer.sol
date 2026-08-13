// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CreateTournamentData, DeployParams } from "@types/registries/TournamentTypes.sol";

/**
 * @title ITournamentInitializer
 * @notice Ringfenced tournament topology create — factories + `TournamentRegistry` writes.
 * @dev Sole caller of `PbrTreasuryFactory` / `PbrFeeHubFactory` and of registry topology
 *      writes (`registerHub` / `createTournament` / `openSeason` / `linkHub`). On new
 *      `DOMESTIC_LEAGUE`, links the hub into existing CONTINENTAL / INTERNATIONAL tournaments.
 *      Orchestrator then queues RoundManager / EligibilityVerifier requests.
 *      Live season rollover: `RoundManager` calls `openSeason` (not full `create`).
 */
interface ITournamentInitializer {
    /// @notice Deploy treasury/hub, write registry topology, open bootstrap seasons.
    function create(DeployParams calldata params) external returns (CreateTournamentData memory data);

    /**
     * @notice Open one registry season (live rollover / append). Does not create tournaments.
     * @dev Callable by `ORCHESTRATOR` or `ROUND_MANAGER` only.
     */
    function openSeason(bytes32 tournamentId, bytes32 seasonId, uint16 seasonStartYear, uint32 finalRound) external;
}
