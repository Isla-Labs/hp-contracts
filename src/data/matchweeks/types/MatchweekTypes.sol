// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Who posted a schedule digest into `FixtureCommitment`.
enum DigestSource {
    HP,
    CRE
}

/// @notice Stored digests for one `(tournament, season, round, schemeEpoch)` key.
struct FixtureDigest {
    bytes32 hpDigest;
    bytes32 creDigest;
    uint32 schemeEpoch;
    bool applied;
}
