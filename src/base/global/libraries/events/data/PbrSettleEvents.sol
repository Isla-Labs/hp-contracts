// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library PbrSettleEvents {
    event SettleRequested(
        bytes32 indexed requestId,
        bytes32 indexed tournamentId,
        address indexed treasury,
        uint16 season,
        uint32 roundNumber,
        uint256 vaultCount
    );

    event SettleFulfilled(
        bytes32 indexed requestId,
        bytes32 indexed tournamentId,
        uint16 season,
        uint32 roundNumber,
        uint256 adjTotalPoints,
        uint256 vaultCount
    );

    event SettleFailed(bytes32 indexed requestId, bytes32 indexed tournamentId, bytes reason);
}
