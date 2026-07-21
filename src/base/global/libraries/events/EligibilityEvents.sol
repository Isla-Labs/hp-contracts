// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Position } from "@base/global/types/PlayerSetTypes.sol";

library EligibilityEvents {
    event AppearancesRecorded(uint256 count);

    event MinutesUpdated(
        bytes32 indexed playerId, Position indexed position, uint32 addedMins, uint32 cumulativeMins, Position expectedPosition
    );

    /// @notice Emitted when one or more tracked players need a CRE DOB fetch.
    event BirthDateFetchNeeded(bytes32[] playerIds);

    event BirthDateUpdated(bytes32 indexed playerId, uint256 birthDate);
}
