// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { HistoricalFixturePhase } from "@types/data/PbrHistoricalTypes.sol";

library PbrHistoricalErrors {
    error ZeroAddress();
    error ZeroId();
    error Unauthorized();
    error UnknownOracleRequest(bytes32 requestId);
    error NoSeasons(bytes32 tournamentId);
    error EmptyFixtures(bytes32 tournamentId, uint16 seasonStartYear, uint32 roundNumber);
    error ZeroHash();
    error FixtureDigestExists(bytes32 fixtureId);
    error FixturePending(bytes32 fixtureJobId, bytes32 requestId);
    error FixtureAlreadyDone(bytes32 fixtureId);
    error BadFixturePhase(bytes32 fixtureJobId, HistoricalFixturePhase actual, HistoricalFixturePhase expected);
    error FixtureIdMismatch(bytes32 expected, bytes32 actual);
}
