// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundSchedule } from "@types/registries/TournamentTypes.sol";

/// @notice Vault-grade tournament registry stub for PlayerVault / PbrTreasury unit tests.
contract MockTournamentRegistry {
    mapping(bytes32 tournamentId => address) public pbrTreasuryOf;
    mapping(bytes32 tournamentId => mapping(uint16 seasonStartYear => mapping(uint32 round => bool))) public published;
    mapping(bytes32 tournamentId => mapping(uint16 seasonStartYear => mapping(uint32 round => RoundSchedule))) internal
        _rounds;
    mapping(bytes32 tournamentId => mapping(uint16 seasonStartYear => uint32)) public finalRoundOf;

    bytes32 public lastFlushTournamentId;
    uint256 public flushCount;

    function setPbrTreasury(bytes32 tournamentId, address treasury) external {
        pbrTreasuryOf[tournamentId] = treasury;
    }

    function getPbrTreasury(bytes32 tournamentId) external view returns (address) {
        return pbrTreasuryOf[tournamentId];
    }

    function setRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        uint64 startTime,
        uint64 endTime,
        bool isPublished
    ) external {
        published[tournamentId][seasonStartYear][roundNumber] = isPublished;
        bytes32[] memory fixtures = new bytes32[](1);
        fixtures[0] = keccak256(abi.encode(tournamentId, seasonStartYear, roundNumber, "fixture-0"));
        _rounds[tournamentId][seasonStartYear][roundNumber] =
            RoundSchedule({ roundNumber: roundNumber, startTime: startTime, endTime: endTime, fixtureIds: fixtures });
    }

    function setFixtures(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32[] calldata fixtureIds
    ) external {
        RoundSchedule storage round = _rounds[tournamentId][seasonStartYear][roundNumber];
        delete round.fixtureIds;
        for (uint256 i; i < fixtureIds.length; ++i) {
            round.fixtureIds.push(fixtureIds[i]);
        }
    }

    function setFinalRound(bytes32 tournamentId, uint16 seasonStartYear, uint32 finalRound) external {
        finalRoundOf[tournamentId][seasonStartYear] = finalRound;
    }

    function isRoundPublished(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (bool) {
        return published[tournamentId][seasonStartYear][roundNumber];
    }

    function getRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (RoundSchedule memory) {
        return _rounds[tournamentId][seasonStartYear][roundNumber];
    }

    function getFinalRound(bytes32 tournamentId, uint16 seasonStartYear) external view returns (uint32) {
        return finalRoundOf[tournamentId][seasonStartYear];
    }

    function flushPendingUnregisters(bytes32 tournamentId) external {
        lastFlushTournamentId = tournamentId;
        unchecked {
            ++flushCount;
        }
    }
}
