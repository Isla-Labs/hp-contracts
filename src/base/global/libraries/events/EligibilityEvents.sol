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

    event WeightedScoreUpdated(bytes32 indexed playerId, uint256 weightedScoreWad);

    /// @notice Paged score sync completed for `[offset, offset+updated)`.
    event WeightedScoresSynced(uint256 offset, uint256 limit, uint256 updated, uint32 globalRound);

    /// @notice Squad-fill CRE upsert: new `MinutesStore` rows (skips already-tracked ids).
    event SquadPlayersCreated(bytes32 indexed seasonId, uint16 pageFetched, uint256 created, uint256 skipped);

    event SquadPlayerCreated(bytes32 indexed playerId, uint256 birthDate);

    /// @notice CRE set `MinutesStore.name` / `symbol` (first fill only; empty name skipped).
    event SquadPlayerMetadataSet(bytes32 indexed playerId, string name, string symbol);

    event SquadFillPageUpdated(bytes32 indexed seasonId, uint16 previousPage, uint16 nextPage);

    /// @notice Deployed player queued to TransferLocker (continuity under-threshold).
    event PlayerDiscontinued(bytes32 indexed playerId, uint32 effectiveMins);

    /// @notice `INACTIVE` player back above continuity → queued to TransferLocker for reactivate.
    event PlayerReactivateQueued(bytes32 indexed playerId, uint32 effectiveMins);

    /// @notice Daily-active club squad overwritten (`playerCount` = active roster size).
    event SquadListUpdated(bytes32 indexed clubId, uint256 playerCount);

    /// @notice Deployed player left the league (queued to TransferLocker after full sweep).
    event PlayerLeftLeague(bytes32 indexed playerId);

    /// @notice New `TransparentUpgradeableProxy` for a league EligibilityVerifier.
    event EligibilityVerifierProxyCreated(
        address indexed proxy, bytes32 indexed leagueId, address implementation
    );

    /// @notice Governance updated deploy / continuity thresholds (`EligibilityCriteria`).
    event EligibilityThresholdsUpdated(
        uint32 thresholdGk,
        uint32 thresholdUnder21,
        uint32 thresholdOutfield,
        uint32 thresholdNewTransfer,
        uint256 under21Age
    );
}
