// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IDopplerLocker } from "@interfaces/governance/IDopplerLocker.sol";
import { ITransferLocker } from "@interfaces/governance/ITransferLocker.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { Appearance, EligibilityGroups, MinutesStore, SquadList } from "@types/data/EligibilityTypes.sol";

/**
 * @title IEligibilityVerifier
 * @notice Squad-first eligibility store with a recency-weighted rolling minutes score.
 * @dev Intended behind `TransparentUpgradeableProxy`; call `initialize` via proxy constructor data.
 */
interface IEligibilityVerifier {
    function initialize(
        address constitutionalTimelock_,
        address dao_,
        address forwarder_,
        bytes32 expectedWorkflowId_,
        address playerSetRegistry_,
        address tournamentRegistry_,
        address ppmVerifier_,
        address dopplerLocker_,
        address transferLocker_,
        bytes32 leagueId_,
        uint16 baseYear_
    ) external;

    function recordAppearances(bytes32 seasonId, uint16 seasonStartYear, Appearance[] calldata appearances) external;

    /**
     * @notice Recompute scores for a page; enqueue undeployed eligibles; queue lifecycle candidates.
     * @dev Sole write path for `weightedScoreWad`. Globally rate-limited (`RateLimit`).
     *      `groups.newTransfers` = DopplerLocker newTransfer / backFromLoan flag.
     *      `groups.toDeactivate` → TransferLocker (continuity under-threshold).
     *      `groups.toReactivate` → TransferLocker (`INACTIVE` back above continuity).
     */
    function verifyEligibility(uint256 offset, uint256 limit) external returns (EligibilityGroups memory groups);

    function setEligibilityThresholds(
        uint32 thresholdGk_,
        uint32 thresholdUnder21_,
        uint32 thresholdOutfield_,
        uint32 thresholdNewTransfer_,
        uint256 under21Age_
    ) external;

    function eligibilityCriteria()
        external
        view
        returns (
            uint32 thresholdGk_,
            uint32 thresholdUnder21_,
            uint32 thresholdOutfield_,
            uint32 thresholdNewTransfer_,
            uint256 under21Age_
        );

    function playerSetRegistry() external view returns (IPlayerSetRegistry);

    function tournamentRegistry() external view returns (ITournamentRegistry);

    function dopplerLocker() external view returns (IDopplerLocker);

    function transferLocker() external view returns (ITransferLocker);

    function ppmVerifier() external view returns (address);

    function leagueId() external view returns (bytes32);

    function baseYear() external view returns (uint16);

    function playerCount() external view returns (uint256);

    function playerIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory);

    /// @notice CRE cursor: SP `_pgNm` to request next (`0` → `1`; done → `(0, true)`).
    function nextSquadFillPageToFetch(bytes32 seasonId) external view returns (uint16 pageToFetch, bool done);

    /// @notice Timestamp when `seasonId` last hit `SQUAD_FILL_PAGE_DONE` (0 if never).
    function getLastSquadFillSweepAt(bytes32 seasonId) external view returns (uint256);

    /// @notice Latest stored active squad for `clubId` (empty if never synced).
    function getSquadList(bytes32 clubId) external view returns (SquadList memory);

    /// @notice Current club membership for `playerId` (`0` if not on any synced squad).
    function playerClub(bytes32 playerId) external view returns (bytes32);

    /// @notice Full per-player store (includes `name` / `symbol` when CRE has filled them).
    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory);

    /// @notice `true` when `name` is non-empty.
    function hasPlayerMetadata(bytes32 playerId) external view returns (bool);

    /// @notice Compact ids in `playerIds` that are tracked but still missing `name`.
    function playersMissingMetadata(bytes32[] calldata playerIds) external view returns (bytes32[] memory missing);

    /// @notice Next unix time `verifyEligibility` may run (0 = never run / immediately allowed).
    function nextAllowed() external view returns (uint256 timestamp);

    function cooldown() external view returns (uint256);
}
