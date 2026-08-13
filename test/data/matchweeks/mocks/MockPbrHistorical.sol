// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Captures peer-kick `openHistorical` from RoundManager Live transition.
contract MockPbrHistorical {
    bytes32 public lastOpenedTournamentId;
    uint256 public openCount;

    function openHistorical(bytes32 tournamentId) external returns (bytes32[] memory requestIds) {
        lastOpenedTournamentId = tournamentId;
        unchecked {
            ++openCount;
        }
        requestIds = new bytes32[](0);
    }
}
