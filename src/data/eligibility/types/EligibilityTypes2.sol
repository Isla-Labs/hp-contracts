// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Position } from "@base/global/types/PlayerSetTypes.sol";

/// @dev `Position` has 14 variants (GK … ST); index = `uint8(Position)`.
uint256 constant POSITION_COUNT = 14;

/// @dev Sentinel in `squadFillPage[seasonId]`: season sweep is complete.
///      Historical seasons stay here; daily-active seasons may restart from page 1 after an interval.
uint16 constant SQUAD_FILL_PAGE_DONE = 1000;

/// @notice Per-player eligibility store; name/symbol deferred to DeployDoppler.
struct MinutesStore {
    /// @dev Argmax of season minutes; default `Position(0)` until PPM derives it.
    Position expectedPosition;
    /// @dev Unix timestamp; set by squad-fill CRE report.
    uint256 birthDate;
    SeasonMinutes[] seasonMinutes;
}

/// @notice Minutes for one competition calendar (`seasonId` = HPID of tournamentCalendarUuid).
struct SeasonMinutes {
    bytes32 seasonId; // tournamentCalendar
    uint16 seasonStartYear;
    uint32[POSITION_COUNT] minsByPosition;
}

/// @notice Single-match appearance delta; season is passed once per `recordAppearances` batch.
struct Appearance {
    bytes32 playerId;
    Position position;
    uint32 minsPlayed;
}

/**
 * @notice CRE squads-historical report.
 * @dev `pageFetched` is the SP `_pgNm` (1-indexed) that produced this batch.
 *      `nextPage` is stored as the cursor: `pageFetched + 1`, same page (partial drain),
 *      or `SQUAD_FILL_PAGE_DONE`.
 */
struct SquadFillReport {
    bytes32 seasonId;
    uint16 pageFetched;
    uint16 nextPage;
    bytes32[] playerIds;
    uint256[] birthDates;
}
