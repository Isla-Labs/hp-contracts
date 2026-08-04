// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library MatchweekEvents {
    event FinalRoundSet(
        bytes32 indexed tournamentId, bytes32 indexed seasonId, uint16 indexed seasonStartYear, uint32 finalRound
    );
    event RoundUpserted(bytes32 indexed tournamentId, uint16 indexed seasonStartYear, uint32 roundNumber);
}
