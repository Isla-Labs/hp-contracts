// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DigestSource } from "@src/data/matchweeks/types/MatchweekTypes.sol";

library MatchweekEvents {
    event RoundManagerSet(address indexed roundManager);

    event ScheduleDigestCommitted(
        bytes32 indexed key,
        DigestSource source,
        bytes32 indexed tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        uint32 schemeEpoch,
        bytes32 digest
    );

    event ScheduleCongruent(
        bytes32 indexed key,
        bytes32 indexed tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        uint32 schemeEpoch,
        bytes32 digest
    );

    event ScheduleApplied(
        bytes32 indexed key,
        bytes32 indexed tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        uint32 schemeEpoch
    );
}
