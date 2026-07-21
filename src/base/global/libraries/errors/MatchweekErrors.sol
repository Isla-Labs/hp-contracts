// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library MatchweekErrors {
    error ZeroAddress();
    error ZeroId();
    error ZeroDigest();
    error NotAuthorized();
    error AlreadyApplied(bytes32 key);
    error DigestConflict(bytes32 key, bytes32 existing, bytes32 provided);
    error DigestMismatch(bytes32 key, bytes32 expected, bytes32 actual);
    error NotCongruent(bytes32 key);
    error RoundManagerAlreadySet();
    error InvalidSchemeEpoch();
}
