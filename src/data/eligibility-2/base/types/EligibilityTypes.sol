// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title EligibilityTypes (eligibility-2)
 * @notice CVM squad-sync types: pull request → one-club (or club-page) fulfill.
 * @dev At 5M callback gas the worker should usually return a full club
 *      (`playerOffset == 0` and `playerIds.length == playerTotal`). Partial
 *      pages are still accepted when a squad exceeds the gas budget.
 */

/// @notice Which sync pass owns the single in-flight cursor.
enum SyncKind {
    None,
    Historical,
    Latest
}

/// @notice Args encoded into `CvmRouter.sendRequest` for squad jobs.
/// @dev Worker fetches the full SP squads endpoint for `(leagueId, seasonId)`,
///      then returns the club at `clubIndex` starting at `playerOffset`.
struct SquadsRequest {
    bytes32 leagueId;
    bytes32 seasonId;
    uint16 clubIndex;
    uint16 playerOffset;
}

/// @notice One fulfill payload: a single club, optionally a player-page slice.
struct SquadsCallback {
    bytes32 leagueId;
    bytes32 seasonId;
    bytes32 clubId;
    /// @dev 0-based index into the season's club list.
    uint16 clubIndex;
    /// @dev Total clubs in the season snapshot (constant for the sync).
    uint16 clubCount;
    /// @dev Start index of this page within the club roster.
    uint16 playerOffset;
    /// @dev Players in this club after `type == player` filter.
    uint16 playerTotal;
    bytes32[] playerIds;
    uint32[] birthDates;
}

/// @notice Onchain cursor for the active historical / latest sync.
struct SyncCursor {
    SyncKind kind;
    bytes32 leagueId;
    bytes32 seasonId;
    /// @dev Next expected `SquadsCallback.clubIndex`.
    uint16 expectClubIndex;
    /// @dev Next expected `SquadsCallback.playerOffset` within that club.
    uint16 expectPlayerOffset;
    /// @dev Set from the first successful fulfill; must stay constant.
    uint16 clubCount;
    /// @dev In-flight request; zero when idle between auto-chains / done.
    bytes32 pendingRequestId;
}
