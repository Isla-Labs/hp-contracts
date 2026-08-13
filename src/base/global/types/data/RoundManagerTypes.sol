// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title RoundManagerTypes
 * @notice Fetch state machine types for `RoundManager`.
 */

/// @notice Tournament-level fetch phase (across bootstrap seasons).
enum RoundFetchPhase {
    None,
    /// @dev Walking bootstrap seasons earliest → latest.
    Historical,
    /// @dev Historical done; continual live sync applies to the latest season only.
    Live
}

/// @notice Per-season oracle step within `Historical` (and later `Live` sync).
enum SeasonFetchStep {
    /// @dev One call: all rounds with `startTime` / `endTime` (fixtureIds empty).
    FormatRounds,
    /// @dev Paged calls: fixtures for up to 10 rounds (≤100 fixtures) per request.
    UpsertFixtures
}

/// @notice Discriminator for `CvmJob.RoundSync` (Live) responses only — Historical has no kind byte.
enum LiveRoundSyncKind {
    /// @dev `abi.encode(uint8(Refresh), RoundSchedule[])` — apply as Format/Upsert for latest.
    Refresh,
    /// @dev `abi.encode(uint8(OpenSeason), bytes32 seasonId, uint16 year, uint32 finalRound)`.
    OpenSeason
}

/// @notice One calendar season under a tournament (id + local start year).
struct SeasonRef {
    bytes32 seasonId;
    uint16 seasonStartYear;
}

/**
 * @notice Per-tournament fetch cursor (seasons stored ascending by `seasonStartYear`).
 * @dev Example 38-round / 380-fixture season: 1× `FormatRounds` + 4× `UpsertFixtures` = 5 requests.
 */
struct TournamentRoundFetch {
    RoundFetchPhase phase;
    SeasonFetchStep step;
    /// @dev Index into `seasons` for the active historical season.
    uint32 seasonIndex;
    /// @dev 1-based next round number for `UpsertFixtures` (0 during `FormatRounds`).
    uint32 fixtureRoundCursor;
    /// @dev Set after a successful `FormatRounds` fulfill (`rounds.length`).
    uint32 finalRound;
    bytes32 pendingRequestId;
    SeasonRef[] seasons;
}
