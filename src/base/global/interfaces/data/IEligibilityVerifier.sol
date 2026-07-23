// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IDeployDoppler } from "@base/global/interfaces/data/IDeployDoppler.sol";
import { IAutomator } from "@base/global/interfaces/governance/IAutomator.sol";
import { IPlayerSetRegistry } from "@base/global/interfaces/IPlayerSetRegistry.sol";
import { ITournamentRegistry } from "@base/global/interfaces/ITournamentRegistry.sol";
import {
    Appearance,
    EligibilityGroups,
    SquadList
} from "@src/data/eligibility/types/EligibilityTypes.sol";

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
        address deployDoppler_,
        address automator_,
        bytes32 leagueId_,
        uint16 baseYear_
    ) external;

    function recordAppearances(bytes32 seasonId, uint16 seasonStartYear, Appearance[] calldata appearances)
        external;

    /**
     * @notice Recompute scores for a page; enqueue undeployed eligibles; discontinue under-threshold deployed.
     * @dev Sole write path for `weightedScoreWad`. Globally rate-limited (`RateLimit`).
     *      `groups.newTransfers` = DeployDoppler newTransfer / backFromLoan flag.
     *      `groups.toDiscontinue` = deployed markets marked `INACTIVE` this page (via Automator).
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

    function deployDoppler() external view returns (IDeployDoppler);

    function automator() external view returns (IAutomator);

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

    /// @notice Next unix time `verifyEligibility` may run (0 = never run / immediately allowed).
    function nextAllowed() external view returns (uint256 timestamp);

    function cooldown() external view returns (uint256);
}
