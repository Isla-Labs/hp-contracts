// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Cursor stub used by SquadStore score sync + EligibilityVerifier season year.
contract MockPbrTreasury {
    uint16 public seasonStartYear;
    uint32 public active;
    uint32 public trading;

    function setCursors(uint16 seasonStartYear_, uint32 active_, uint32 trading_) external {
        seasonStartYear = seasonStartYear_;
        active = active_;
        trading = trading_;
    }

    function getCursors() external view returns (uint16, uint32, uint32) {
        return (seasonStartYear, active, trading);
    }
}
