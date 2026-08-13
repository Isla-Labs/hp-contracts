// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { FixturePhase } from "@types/data/PbrSettleTypes.sol";

library PbrSettleErrors {
    error ZeroAddress();
    error Unauthorized();
    error ZeroHash();
    error ZeroFixture();
    error NoFixtures();
    error LengthMismatch();
    error TreasuryMissing(bytes32 tournamentId);
    error RoundSettlePending(bytes32 roundId);
    error FixturePending(bytes32 fixtureJobId, bytes32 requestId);
    error FixtureAlreadySettled(bytes32 fixtureId);
    error UnknownOracleRequest(bytes32 requestId);
    error BadFixturePhase(bytes32 fixtureJobId, FixturePhase actual, FixturePhase expected);
    error UtilizedHashMismatch(bytes32 expected, bytes32 actual);
    error RoundNotSettlePending(bytes32 roundId);
    error FixtureNotRetryable(bytes32 fixtureJobId, FixturePhase phase);
}
