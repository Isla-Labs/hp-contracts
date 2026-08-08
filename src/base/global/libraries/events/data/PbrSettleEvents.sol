// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library PbrSettleEvents {
    event RoundSettleOpened(
        bytes32 indexed tournamentId,
        address indexed treasury,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32 utilizedHash,
        uint32 fixtureCount
    );

    event FixtureSettleRequested(
        bytes32 indexed requestId,
        bytes32 indexed tournamentId,
        bytes32 indexed fixtureId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32 utilizedHash
    );

    event FixtureSettleProven(
        bytes32 indexed requestId,
        bytes32 indexed tournamentId,
        bytes32 indexed fixtureId,
        bytes32 fixtureDigest,
        bytes32 proofHash,
        uint256 vaultCount
    );

    event FixtureSettleFailed(
        bytes32 indexed requestId, bytes32 indexed tournamentId, bytes32 indexed fixtureId, bytes reason
    );

    event RoundSettleComplete(
        bytes32 indexed tournamentId, uint16 seasonStartYear, uint32 roundNumber, uint32 fixturesSettled
    );
}
