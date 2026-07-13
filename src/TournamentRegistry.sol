// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

contract TournamentRegistry {
    mapping(uint256 => address) public tournamentOwner;
    mapping(uint256 => address) public tournamentToken;
    mapping(uint256 => uint256) public tournamentStartTimestamp;
    mapping(uint256 => uint256) public tournamentEndTimestamp;

    function createTournament(uint256 tournamentId) external {
        tournamentOwner[tournamentId] = msg.sender;
    }
}
