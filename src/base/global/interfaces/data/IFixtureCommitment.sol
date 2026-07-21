// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { RoundSchedule } from "@base/global/types/TournamentTypes.sol";
import { DigestSource, FixtureDigest } from "@src/data/matchweeks/types/MatchweekTypes.sol";

/**
 * @title IFixtureCommitment
 * @notice Commit-then-attest digests for tournament round schedules (no zkVM).
 */
interface IFixtureCommitment {
    function ROUND_SCHEDULE_KIND() external view returns (bytes32);

    function commitmentKey(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        uint32 schemeEpoch
    ) external pure returns (bytes32);

    function computeDigest(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        RoundSchedule calldata round,
        uint32 schemeEpoch
    ) external pure returns (bytes32);

    function commit(
        DigestSource source,
        bytes32 tournamentId,
        uint16 seasonStartYear,
        RoundSchedule calldata round,
        uint32 schemeEpoch
    ) external returns (bytes32 key, bytes32 digest);

    function getCommitment(bytes32 key) external view returns (FixtureDigest memory);

    function isCongruent(bytes32 key) external view returns (bool);

    function markApplied(bytes32 key) external;
}
