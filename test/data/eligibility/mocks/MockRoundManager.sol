// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundFetchPhase } from "@types/data/RoundManagerTypes.sol";

/// @notice RoundManager stub for SquadStore Live rendezvous.
contract MockRoundManager {
    mapping(bytes32 tournamentId => RoundFetchPhase) internal _phase;

    function setFetchPhase(bytes32 tournamentId, RoundFetchPhase phase) external {
        _phase[tournamentId] = phase;
    }

    function getFetchPhase(bytes32 tournamentId) external view returns (RoundFetchPhase) {
        return _phase[tournamentId];
    }
}
