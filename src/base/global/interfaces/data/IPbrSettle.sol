// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { FixtureSettlement, RoundSettlement } from "@types/data/PbrSettleTypes.sol";

/**
 * @title IPbrSettle
 * @notice Fan-out per-fixture `SettleDms`: treasury `utilizedHash` + round fixtures → zk → apply points.
 */
interface IPbrSettle {
    /**
     * @notice Open one `SettleDms` job per round fixture, each bound to `utilizedHash`.
     * @dev Callable only by `TournamentRegistry.getPbrTreasury(tournamentId)`.
     *      Fixture ids are read from `TournamentRegistry.getRound`.
     */
    function settleRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32 utilizedHash
    ) external returns (bytes32[] memory requestIds);

    /**
     * @notice Re-open `SettleDms` for one fixture after oracle `err` exhausted auto-retries (or any `None` phase).
     * @dev Permissionless. Round must still be `Requested`; fixture must be `None` (not in-flight / not Proven).
     */
    function retryFixtureSettle(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32 fixtureId
    ) external returns (bytes32 requestId);

    function roundId(bytes32 tournamentId, uint16 seasonStartYear, uint32 roundNumber) external pure returns (bytes32);

    function fixtureJobId(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32 fixtureId
    ) external pure returns (bytes32);

    function pendingRequest(bytes32 fixtureJobId_) external view returns (bytes32 requestId);

    function getRoundSettlement(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (RoundSettlement memory);

    function getFixtureSettlement(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32 fixtureId
    ) external view returns (FixtureSettlement memory);
}
