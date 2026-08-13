// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { EligibilityGroups } from "@types/initializers/DopplerTypes.sol";
import { MinutesStore, SquadList, VerifySnapshot } from "@types/data/SquadStoreTypes.sol";

/**
 * @title IEligibilityVerifier
 * @notice Permissionless verify scan / Orchestrator deploy+lifecycle handoff.
 * @dev Historical squad bootstrap is `SquadStore.openLeague` (Orchestrator-gated).
 */
interface IEligibilityVerifier {
    /**
     * @notice Decay page scores to each player's league `G_now`; enqueue deploy / lifecycle sets.
     * @dev Public (rate-limited). Score mass comes from SquadStore `recordAppearances`.
     */
    function verifyEligibility(uint256 offset, uint256 limit) external returns (EligibilityGroups memory groups);

    function playerCount() external view returns (uint256);

    function playerIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory);

    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory);

    function getVerifySnapshot(bytes32 playerId) external view returns (VerifySnapshot memory);

    function getSquadList(bytes32 clubId) external view returns (SquadList memory);
}
