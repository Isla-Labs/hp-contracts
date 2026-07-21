// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library EligibilityErrors {
    error ZeroAddress();
    error ZeroId();
    error ZeroWorkflowId();
    error ZeroBirthDate(bytes32 playerId);
    error EmptyName(bytes32 playerId);
    error EmptySymbol(bytes32 playerId);
    error UnknownPlayer(bytes32 playerId);
    error BirthDateAlreadySet(bytes32 playerId, uint256 existing);
    error LengthMismatch(uint256 playerIdsLength, uint256 birthDatesLength);
    error EmptyReport();
}
