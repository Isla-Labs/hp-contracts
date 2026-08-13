// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { HistoricalDmsPhase } from "@types/data/PbrHistoricalTypes.sol";

library PbrHistoricalEvents {
    event HistoricalDmsOpened(bytes32 indexed tournamentId, uint256 seasonCount, bool writeAppearances);

    event HistoricalDmsPhaseChanged(bytes32 indexed tournamentId, HistoricalDmsPhase previous, HistoricalDmsPhase next);

    event HistoricalRoundOpened(
        bytes32 indexed tournamentId,
        bytes32 indexed seasonId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        uint32 fixtureCount
    );

    event HistoricalFixtureRequested(
        bytes32 indexed requestId,
        bytes32 indexed tournamentId,
        bytes32 indexed fixtureId,
        uint16 seasonStartYear,
        uint32 roundNumber
    );

    event HistoricalFixtureApplied(
        bytes32 indexed requestId,
        bytes32 indexed tournamentId,
        bytes32 indexed fixtureId,
        bytes32 rssDigest,
        uint256 appearances,
        bool wroteAppearances
    );

    event HistoricalRoundComplete(
        bytes32 indexed tournamentId, bytes32 indexed seasonId, uint32 roundNumber, uint32 fixturesDone
    );

    event RssDigestStored(bytes32 indexed fixtureId, bytes32 rssDigest);

    event HistoricalFixtureFailed(
        bytes32 indexed requestId, bytes32 indexed tournamentId, bytes32 indexed fixtureId, bytes err
    );

    event HistoricalFixtureRetry(bytes32 indexed tournamentId, bytes32 indexed fixtureId, bytes32 newRequestId);
}
