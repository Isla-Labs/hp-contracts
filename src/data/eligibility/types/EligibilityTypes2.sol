// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Position } from "@base/global/types/PlayerSetTypes.sol";

/// @dev `Position` has 14 variants (GK … ST); index = `uint8(Position)`.
uint256 constant POSITION_COUNT = 14;

/// @notice Per-player eligibility identity + season-scoped minutes (minutes filled by PPM later).
struct MinutesStore {
    string name;
    string symbol;
    /// @dev Argmax of season minutes; default `Position(0)` until PPM derives it.
    Position expectedPosition;
    /// @dev Unix timestamp; set by squad-fill CRE report.
    uint256 birthDate;
    SeasonMinutes[] seasonMinutes;
}

/// @notice Minutes for one competition calendar (`seasonId` = HPID of tournamentCalendarUuid).
struct SeasonMinutes {
    bytes32 seasonId;
    uint16 seasonStartYear;
    uint32[POSITION_COUNT] minsByPosition;
}

/// @notice CRE squad-fill report payload (`abi.encode` of the four parallel arrays).
struct SquadFillReport {
    bytes32[] playerIds;
    string[] names;
    string[] symbols;
    uint256[] birthDates;
}
