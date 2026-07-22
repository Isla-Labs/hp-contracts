// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Position } from "@base/global/types/PlayerSetTypes.sol";

library EligibilityEvents {
    event AppearancesRecorded(uint256 count);

    event MinutesUpdated(
        bytes32 indexed playerId,
        bytes32 indexed seasonId,
        uint32 indexed roundNumber,
        Position position,
        uint32 addedMins,
        uint32 cumulativeMins,
        Position expectedPosition
    );

    event WeightedScoreUpdated(
        bytes32 indexed playerId, uint256 weightedScoreWad, uint32 scoreAsOfGlobalRound
    );

    /// @notice Paged score sync completed for `[offset, offset+updated)`.
    event WeightedScoresSynced(uint256 offset, uint256 limit, uint256 updated, uint32 globalRound);

    /// @notice Squad-fill CRE upsert: new `MinutesStore` rows (skips already-tracked ids).
    event SquadPlayersCreated(bytes32 indexed seasonId, uint16 pageFetched, uint256 created, uint256 skipped);

    event SquadPlayerCreated(bytes32 indexed playerId, uint256 birthDate);

    event SquadFillPageUpdated(bytes32 indexed seasonId, uint16 previousPage, uint16 nextPage);
}
