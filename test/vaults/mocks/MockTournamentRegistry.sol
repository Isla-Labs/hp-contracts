// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundSchedule } from "@types/registries/TournamentTypes.sol";

/// @notice Vault-grade tournament registry stub for PlayerVault / PbrTreasury unit tests.
contract MockTournamentRegistry {
    mapping(bytes32 tournamentId => address) public pbrTreasuryOf;
    mapping(bytes32 tournamentId => mapping(uint16 season => mapping(uint32 round => bool))) public published;
    mapping(bytes32 tournamentId => mapping(uint16 season => mapping(uint32 round => RoundSchedule))) internal _rounds;
    mapping(bytes32 tournamentId => mapping(uint16 season => uint32)) public finalRoundOf;

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
        uint16 season,
        uint32 roundNumber,
        uint64 startTime,
        uint64 endTime,
        bool isPublished
    ) external {
        published[tournamentId][season][roundNumber] = isPublished;
        _rounds[tournamentId][season][roundNumber] = RoundSchedule({
            roundNumber: roundNumber, startTime: startTime, endTime: endTime, fixtureIds: new bytes32[](0)
        });
    }

    function setFinalRound(bytes32 tournamentId, uint16 season, uint32 finalRound) external {
        finalRoundOf[tournamentId][season] = finalRound;
    }

    function isRoundPublished(bytes32 tournamentId, uint16 season, uint32 roundNumber) external view returns (bool) {
        return published[tournamentId][season][roundNumber];
    }

    function getRound(
        bytes32 tournamentId,
        uint16 season,
        uint32 roundNumber
    ) external view returns (RoundSchedule memory) {
        return _rounds[tournamentId][season][roundNumber];
    }

    function getFinalRound(bytes32 tournamentId, uint16 season) external view returns (uint32) {
        return finalRoundOf[tournamentId][season];
    }

    function flushPendingUnregisters(bytes32 tournamentId) external {
        lastFlushTournamentId = tournamentId;
        unchecked {
            ++flushCount;
        }
    }
}
