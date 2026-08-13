// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Appearance, HistoricalDmsPhase, TournamentHistoricalDms } from "@types/data/PbrHistoricalTypes.sol";

/**
 * @title IPbrHistorical
 * @notice Historical DMS ingest after RoundManager (+ SquadStore for domestic) bootstrap.
 * @dev Per round: fan out ≤10 `HistoricalDms` jobs (Settle pattern). Digests always;
 *      Appearances → SquadStore only for `DOMESTIC_LEAGUE`. Failed fixtures auto-retry.
 */
interface IPbrHistorical {
    /**
     * @notice Arm historical DMS for `tournamentId` (idempotent if already Running/Complete).
     * @dev Callable by `RoundManager` or `SquadStore` after peer Live checks.
     * @return requestIds First round's per-fixture request ids (empty if already open).
     */
    function openHistorical(bytes32 tournamentId) external returns (bytes32[] memory requestIds);

    function getFetchState(bytes32 tournamentId) external view returns (TournamentHistoricalDms memory);

    function getFetchPhase(bytes32 tournamentId) external view returns (HistoricalDmsPhase);

    function getRssDigest(bytes32 fixtureId) external view returns (bytes32);

    function getAppearances(bytes32 fixtureId) external view returns (Appearance[] memory);

    function fixtureJobId(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32 fixtureId
    ) external pure returns (bytes32);
}
