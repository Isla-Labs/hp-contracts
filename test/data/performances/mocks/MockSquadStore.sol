// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Appearance } from "@types/data/PbrHistoricalTypes.sol";

/// @notice Captures domestic `recordAppearances` from PbrHistorical.
contract MockSquadStore {
    bytes32 public lastSeasonId;
    uint16 public lastSeasonStartYear;
    uint256 public recordCount;
    uint256 public lastAppearanceCount;
    Appearance[] internal _lastAppearances;

    function recordAppearances(bytes32 seasonId, uint16 seasonStartYear, Appearance[] calldata appearances) external {
        lastSeasonId = seasonId;
        lastSeasonStartYear = seasonStartYear;
        lastAppearanceCount = appearances.length;
        delete _lastAppearances;
        for (uint256 i; i < appearances.length; ++i) {
            _lastAppearances.push(appearances[i]);
        }
        unchecked {
            ++recordCount;
        }
    }

    function lastAppearances() external view returns (Appearance[] memory) {
        return _lastAppearances;
    }
}
