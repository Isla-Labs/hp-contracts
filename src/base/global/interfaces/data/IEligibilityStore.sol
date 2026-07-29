// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import {
    Appearance,
    MinutesStore,
    SeasonRun,
    SortCursor,
    SquadList,
    VerifySnapshot,
    WorkflowControl
} from "@data/eligibility/types/EligibilityTypes.sol";

/**
 * @title IEligibilityStore
 * @notice CRE squads data plane + minutes / score storage (separate from EligibilityVerifier).
 * @dev Intended behind `TransparentUpgradeableProxy`. CRE → `onReport`; PpmVerifier →
 *      `recordAppearances`; EligibilityVerifier → privileged verify helpers.
 */
interface IEligibilityStore {
    function initialize(bytes32 workflowId_, uint16 baseYear_, address eligibilityVerifier_) external;

    function recordAppearances(bytes32 seasonId, uint16 seasonStartYear, Appearance[] calldata appearances) external;

    function queueLeague(bytes32 leagueId, bytes32[] calldata seasonIds, uint16[] calldata seasonStartYears) external;

    function setCurrentSeasonStartYear(uint16 year) external;

    function setExpectedWorkflowId(bytes32 workflowId_) external;

    function setForwarderAddress(address forwarder_) external;

    /// @notice Verify-page GC: purge stale deactivated rows. Returns true if slot compacted.
    function purgeIfStale(uint256 index) external returns (bool purged);

    /// @notice Idle-decay `currentLeagueId` score to that league's `G_now`.
    function syncPlayerScore(bytes32 playerId) external;

    /// @notice Sync then return lean classify snapshot (`currentLeagueId` row only).
    function syncAndSnapshot(bytes32 playerId) external returns (VerifySnapshot memory snap);

    /// @notice Lean classify view: scalars + `LeagueMinutes` for `currentLeagueId` only.
    function getVerifySnapshot(bytes32 playerId) external view returns (VerifySnapshot memory);

    function takePendingLeftLeague() external returns (bytes32[] memory ids);

    function takePendingClubChanged() external returns (bytes32[] memory ids);

    function takePendingLeagueChanged() external returns (bytes32[] memory ids);

    function workflowControl() external view returns (WorkflowControl memory);

    function runNumber() external view returns (uint16);

    function leagueCount() external view returns (uint256);

    function leagueIdAt(uint256 leagueIndex) external view returns (bytes32);

    function leagueSeasons(uint256 leagueIndex) external view returns (SeasonRun[] memory);

    function transientStatus()
        external
        view
        returns (
            bytes32 leagueId,
            bytes32 seasonId,
            uint16 pageFetched,
            uint16 nextPage,
            uint16 personsOffset,
            uint256 stagedPlayers
        );

    function sortCursor() external view returns (SortCursor memory);

    function pendingLeftLeagueCount() external view returns (uint256);

    function pendingClubChangedCount() external view returns (uint256);

    function pendingLeagueChangedCount() external view returns (uint256);

    function nextCurrentSeason() external view returns (bool ready, bytes32 leagueId, bytes32 seasonId);

    function lastCurrentPassCompletedAt() external view returns (uint64);

    function scoreBaseYear() external view returns (uint16);

    function playerCount() external view returns (uint256);

    function playerIdAt(uint256 index) external view returns (bytes32);

    function playerIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory);

    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory);

    function getPlayerMetadata(bytes32 playerId)
        external
        view
        returns (string memory name, string memory symbol, bool metadataSet);

    function getSquadList(bytes32 clubId) external view returns (SquadList memory);

    function isTracked(bytes32 playerId) external view returns (bool);

    function eligibilityVerifier() external view returns (address);
}
