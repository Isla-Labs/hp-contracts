// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundSchedule } from "@types/TournamentTypes.sol";

/**
 * @title IRoundManager
 * @notice Applies CRE/HP-attested round schedules into `TournamentRegistry`.
 */
interface IRoundManager {
    function applyRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        RoundSchedule calldata round,
        uint32 schemeEpoch
    ) external;

    function applyRounds(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        RoundSchedule[] calldata rounds,
        uint32 schemeEpoch
    ) external;
}
