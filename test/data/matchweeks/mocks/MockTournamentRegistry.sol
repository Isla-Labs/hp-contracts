// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundSchedule, TournamentType } from "@types/registries/TournamentTypes.sol";

/// @notice Round-calendar surface for RoundManager tests.
contract MockTournamentRegistry {
    mapping(bytes32 tournamentId => TournamentType) internal _types;
    mapping(bytes32 tournamentId => mapping(uint16 seasonStartYear => uint32)) internal _finalRound;
    mapping(
        bytes32 tournamentId => mapping(uint16 seasonStartYear => mapping(uint32 roundNumber => RoundSchedule))
    ) internal _rounds;
    mapping(bytes32 tournamentId => mapping(uint16 seasonStartYear => mapping(uint32 roundNumber => bool))) internal
        _published;

    uint256 public upsertRoundCount;
    uint256 public upsertRoundsCount;
    uint256 public lastUpsertBatchSize;

    function setTournamentType(bytes32 tournamentId, TournamentType tournamentType) external {
        _types[tournamentId] = tournamentType;
    }

    function setFinalRound(bytes32 tournamentId, uint16 seasonStartYear, uint32 finalRound) external {
        _finalRound[tournamentId][seasonStartYear] = finalRound;
    }

    function getTournamentType(bytes32 tournamentId) external view returns (TournamentType) {
        return _types[tournamentId];
    }

    function getFinalRound(bytes32 tournamentId, uint16 seasonStartYear) external view returns (uint32) {
        return _finalRound[tournamentId][seasonStartYear];
    }

    function upsertRound(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule calldata round) external {
        _storeRound(tournamentId, seasonStartYear, round);
        unchecked {
            ++upsertRoundCount;
        }
    }

    function upsertRounds(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule[] calldata rounds) external {
        uint256 length = rounds.length;
        for (uint256 i; i < length; ++i) {
            _storeRound(tournamentId, seasonStartYear, rounds[i]);
        }
        lastUpsertBatchSize = length;
        unchecked {
            ++upsertRoundsCount;
        }
    }

    function getRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (RoundSchedule memory) {
        return _rounds[tournamentId][seasonStartYear][roundNumber];
    }

    function isRoundPublished(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (bool) {
        return _published[tournamentId][seasonStartYear][roundNumber];
    }

    function _storeRound(bytes32 tournamentId, uint16 seasonStartYear, RoundSchedule memory round) internal {
        _rounds[tournamentId][seasonStartYear][round.roundNumber] = round;
        _published[tournamentId][seasonStartYear][round.roundNumber] = true;
    }
}
