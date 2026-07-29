// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IEligibilityStore } from "@interfaces/data/IEligibilityStore.sol";
import {
    EligibilityGroups,
    MinutesStore,
    SquadList,
    VerifySnapshot
} from "@data/eligibility/types/EligibilityTypes.sol";

/**
 * @title IEligibilityVerifier
 * @notice Criteria + verify scan; Automator → DopplerLocker / TransferLocker.
 * @dev Minutes / CRE state live on `IEligibilityStore`. This contract classifies cohorts
 *      and enqueues deploy / lifecycle actions. Intended behind `TransparentUpgradeableProxy`.
 */
interface IEligibilityVerifier {
    function initialize() external;

    /**
     * @notice Decay page scores to `G_now`; enqueue undeployed eligibles; queue lifecycle candidates.
     * @dev Globally rate-limited (`RateLimit`). Score mass comes from Store `recordAppearances`.
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

    function store() external view returns (IEligibilityStore);

    /// @notice Name/symbol only (forwards to Store; DopplerLocker enqueue oracle).
    function getPlayerMetadata(bytes32 playerId)
        external
        view
        returns (string memory name, string memory symbol, bool metadataSet);

    function playerCount() external view returns (uint256);

    function playerIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory);

    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory);

    function getVerifySnapshot(bytes32 playerId) external view returns (VerifySnapshot memory);

    function getSquadList(bytes32 clubId) external view returns (SquadList memory);

    /// @notice Next unix time `verifyEligibility` may run (0 = never run / immediately allowed).
    function nextAllowed() external view returns (uint256 timestamp);

    function cooldown() external view returns (uint256);
}
