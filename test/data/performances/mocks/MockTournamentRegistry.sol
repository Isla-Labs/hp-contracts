// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundSchedule, TournamentType } from "@types/registries/TournamentTypes.sol";

/// @notice Round-calendar + treasury surface for PbrHistorical / PbrSettle tests.
contract MockTournamentRegistry {
    mapping(bytes32 tournamentId => TournamentType) internal _types;
    mapping(bytes32 tournamentId => address) public pbrTreasuryOf;
    mapping(bytes32 tournamentId => mapping(uint16 seasonStartYear => uint32)) internal _finalRound;
    mapping(
        bytes32 tournamentId => mapping(uint16 seasonStartYear => mapping(uint32 roundNumber => RoundSchedule))
    ) internal _rounds;

    function setTournamentType(bytes32 tournamentId, TournamentType tournamentType) external {
        _types[tournamentId] = tournamentType;
    }

    function setPbrTreasury(bytes32 tournamentId, address treasury) external {
        pbrTreasuryOf[tournamentId] = treasury;
    }

    function getPbrTreasury(bytes32 tournamentId) external view returns (address) {
        return pbrTreasuryOf[tournamentId];
    }

    function setFinalRound(bytes32 tournamentId, uint16 seasonStartYear, uint32 finalRound) external {
        _finalRound[tournamentId][seasonStartYear] = finalRound;
    }

    function setRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32[] memory fixtureIds
    ) external {
        _rounds[tournamentId][seasonStartYear][roundNumber] = RoundSchedule({
            roundNumber: roundNumber,
            startTime: uint64(roundNumber),
            endTime: uint64(roundNumber) + 1,
            fixtureIds: fixtureIds
        });
    }

    function getTournamentType(bytes32 tournamentId) external view returns (TournamentType) {
        return _types[tournamentId];
    }

    function getFinalRound(bytes32 tournamentId, uint16 seasonStartYear) external view returns (uint32) {
        return _finalRound[tournamentId][seasonStartYear];
    }

    function getRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (RoundSchedule memory) {
        return _rounds[tournamentId][seasonStartYear][roundNumber];
    }
}
