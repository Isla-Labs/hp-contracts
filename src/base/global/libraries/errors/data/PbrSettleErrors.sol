// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library PbrSettleErrors {
    error ZeroAddress();
    error Unauthorized();
    error LengthMismatch();
    error ZeroMAdj();
    error EmptyVaults();
    error TreasuryMissing(bytes32 tournamentId);
    error SettlePending(bytes32 jobId, bytes32 requestId);
    error UnknownOracleRequest(bytes32 requestId);
    error MAdjMismatch(uint256 sumPoints, uint256 adjTotalPoints);
}
