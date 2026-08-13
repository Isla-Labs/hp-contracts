// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { LifecycleReason } from "@types/initializers/LifecycleTypes.sol";

/**
 * @title IOrchestrator
 * @notice Named entry surface for deployment / lifecycle flows.
 * @dev Intake (`queuePlayers` / `enqueueLifecycle`) is deployer-gated (HP multisig + EligibilityVerifier).
 *      MarketInitializer / LifecycleManager accept this contract alone for intake + process;
 *      `processQueue` / `processLifecycle` are the public kicks (rate-limited here).
 */
interface IOrchestrator {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /**
     * @notice Intake players for market deploy (forwards to `MarketInitializer.queueAssets`).
     * @dev Deployer-gated — HP multisig + EligibilityVerifier.
     */
    function queueAssets(bytes32 leagueId, bytes32 seasonId, bytes32[] calldata playerIds) external;

    /**
     * @notice Kick the next mature market queue entry (forwards to `MarketInitializer.deployAssets`).
     * @return requestId FinalConfig request id, or `0` when a DeployReady resume ran onchain.
     */
    function processQueue() external returns (bytes32 requestId);

    /**
     * @notice Intake players for lifecycle review (forwards to `LifecycleManager.enqueueLifecycle`).
     * @dev Deployer-gated — HP multisig + EligibilityVerifier.
     */
    function queueChanges(
        bytes32[] calldata playerIds,
        LifecycleReason reason,
        uint32[] calldata effectiveMins
    ) external;

    /**
     * @notice Kick the next mature lifecycle entry (forwards to `LifecycleManager.processLifecycle`).
     * @return requestId LeagueTransfer request id, or `0` when deactivate applied onchain.
     */
    function processLifecycle() external returns (bytes32 requestId);
}
