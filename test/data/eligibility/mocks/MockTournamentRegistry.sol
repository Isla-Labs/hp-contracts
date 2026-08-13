// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice TournamentRegistry stub for SquadStore scoring + EligibilityVerifier season year.
contract MockTournamentRegistry {
    mapping(bytes32 tournamentId => address) public pbrTreasuryOf;
    mapping(bytes32 tournamentId => mapping(uint16 seasonStartYear => bytes32)) internal _seasonId;
    mapping(bytes32 tournamentId => mapping(uint16 seasonStartYear => uint32)) internal _finalRound;

    function setPbrTreasury(bytes32 tournamentId, address treasury) external {
        pbrTreasuryOf[tournamentId] = treasury;
    }

    function setSeasonId(bytes32 tournamentId, uint16 seasonStartYear, bytes32 seasonId) external {
        _seasonId[tournamentId][seasonStartYear] = seasonId;
    }

    function setFinalRound(bytes32 tournamentId, uint16 seasonStartYear, uint32 finalRound) external {
        _finalRound[tournamentId][seasonStartYear] = finalRound;
    }

    function getPbrTreasury(bytes32 tournamentId) external view returns (address) {
        return pbrTreasuryOf[tournamentId];
    }

    function getSeasonId(bytes32 tournamentId, uint16 seasonStartYear) external view returns (bytes32) {
        return _seasonId[tournamentId][seasonStartYear];
    }

    function getFinalRound(bytes32 tournamentId, uint16 seasonStartYear) external view returns (uint32) {
        return _finalRound[tournamentId][seasonStartYear];
    }
}
