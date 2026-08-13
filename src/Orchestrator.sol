// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { RateLimit } from "@base/abstract/RateLimit.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { DeploymentsErrors as Errors } from "@errors/initializers/DeploymentsErrors.sol";
import { OrchestratorEvents as Events } from "@events/OrchestratorEvents.sol";
import { IRoundManager } from "@interfaces/data/IRoundManager.sol";
import { ISquadStore } from "@interfaces/data/ISquadStore.sol";
import { ILifecycleManager } from "@interfaces/initializers/ILifecycleManager.sol";
import { IMarketInitializer } from "@interfaces/initializers/IMarketInitializer.sol";
import { ITournamentInitializer } from "@interfaces/initializers/ITournamentInitializer.sol";
import { IOrchestrator } from "@interfaces/IOrchestrator.sol";
import { LifecycleReason } from "@types/initializers/LifecycleTypes.sol";
import { CreateTournamentData, DeployParams, TournamentType } from "@types/registries/TournamentTypes.sol";

/**
 * @title Orchestrator
 * @notice Named entry surface for HighPotential deployment / lifecycle flows.
 * @dev Topology create is ringfenced in `TournamentInitializer`; this contract sequences that
 *      create with round/squad bootstrap, and is the sole caller of `MarketInitializer` /
 *      `LifecycleManager` intake + process.
 *
 *      Access:
 *        - `onlyAdmin` (`HP_MULTISIG`) — `createTournament`
 *        - `onlyDeployer` (`HP_MULTISIG` + `ELIGIBILITY_VERIFIER`) — `queuePlayers` / `enqueueLifecycle`
 *        - `processQueue` / `processLifecycle` — permissionless (rate-limited here)
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract Orchestrator is AddressBook, RateLimit, IOrchestrator {
    uint256 public constant DEFAULT_DEPLOY_COOLDOWN = 1 hours;

    /**
     * @param addressProvider_ Canonical `AddressProvider`.
     * @param deployCooldown_ Min seconds between `processQueue` / `processLifecycle` kicks.
     */
    constructor(
        address addressProvider_,
        uint256 deployCooldown_
    ) AddressBook(addressProvider_) RateLimit(deployCooldown_ == 0 ? DEFAULT_DEPLOY_COOLDOWN : deployCooldown_) {
        if (addressProvider_ == address(0)) revert Errors.ZeroAddress();
    }

    // --------------------------------------------
    //  Access Control
    // --------------------------------------------

    modifier onlyAdmin() {
        if (msg.sender != _getAddress(_addressKey(Addresses.HP_MULTISIG))) revert Errors.Unauthorized();
        _;
    }

    /// @dev HP multisig always; EligibilityVerifier when registered (soft lookup).
    modifier onlyDeployer() {
        address sender = msg.sender;
        if (sender == _getAddress(_addressKey(Addresses.HP_MULTISIG))) {
            _;
            return;
        }
        address verifier = addressProvider.get(_addressKey(Addresses.ELIGIBILITY_VERIFIER));
        if (verifier == address(0) || sender != verifier) revert Errors.Unauthorized();
        _;
    }

    // --------------------------------------------
    //  AddressBook resolvers
    // --------------------------------------------

    function _tournamentInitializer() private view returns (ITournamentInitializer) {
        return ITournamentInitializer(_getAddress(_addressKey(Addresses.TOURNAMENT_INITIALIZER)));
    }

    function _roundManager() private view returns (IRoundManager) {
        return IRoundManager(_getAddress(_addressKey(Addresses.ROUND_MANAGER)));
    }

    function _squadStore() private view returns (ISquadStore) {
        return ISquadStore(_getAddress(_addressKey(Addresses.SQUAD_STORE)));
    }

    function _marketInitializer() private view returns (IMarketInitializer) {
        return IMarketInitializer(_getAddress(_addressKey(Addresses.MARKET_INITIALIZER)));
    }

    function _lifecycleManager() private view returns (ILifecycleManager) {
        return ILifecycleManager(_getAddress(_addressKey(Addresses.LIFECYCLE_MANAGER)));
    }

    // --------------------------------------------
    //  Create Tournament
    // --------------------------------------------

    /**
     * @notice Create a tournament, then request round/squad bootstrap.
     * @dev Sequence:
     *      1) `TournamentInitializer.create` — factories + registry hub/tournament/seasons
     *      2) `RoundManager.openTournament` — historical round calendar
     *      3) `SquadStore.openLeague` when `DOMESTIC_LEAGUE` (historical squads)
     *      When both peers hit Live (rounds alone for non-domestic), they kick `PbrHistorical`.
     * @return data Topology result (already written on-registry).
     * @return roundRequestId First round bootstrap request id.
     * @return squadRequestId First squad bootstrap request id (`0` for non-leagues).
     */
    function createTournament(DeployParams calldata params)
        external
        onlyAdmin
        returns (CreateTournamentData memory data, bytes32 roundRequestId, bytes32 squadRequestId)
    {
        data = _tournamentInitializer().create(params);

        roundRequestId = _roundManager().openTournament(data.tournamentId, data.seasonIds, data.seasonStartYears);
        emit Events.HistoricalRoundFetchQueued(data.tournamentId, data.seasonIds, data.seasonStartYears, roundRequestId);

        if (data.tournamentType == TournamentType.DOMESTIC_LEAGUE) {
            squadRequestId = _squadStore().openLeague(data.tournamentId, data.seasonIds, data.seasonStartYears);
            emit Events.HistoricalSquadFetchQueued(
                data.tournamentId, data.seasonIds, data.seasonStartYears, squadRequestId
            );
        } else {
            // TODO: register league squads under cup treasury
            // _knockoutManager().syncVaults(data.tournamentId);
            // _knockoutManager().refreshKnockouts();
        }

        emit Events.TournamentFlowDeployed(
            data.tournamentId, data.tournamentType, data.pbrTreasury, data.pbrFeeHub, data.seasonIds.length
        );
    }

    // --------------------------------------------
    //  Deploy Assets
    // --------------------------------------------

    /**
     * @notice Queue players for market deploy via `MarketInitializer`.
     * @dev Deployer-gated (HP multisig + EligibilityVerifier). MarketInitializer accepts
     *      this contract alone for `queueAssets`.
     */
    function queueAssets(bytes32 leagueId, bytes32 seasonId, bytes32[] calldata playerIds) external onlyDeployer {
        _marketInitializer().queueAssets(leagueId, seasonId, playerIds);
        emit Events.MarketQueued(leagueId, seasonId, playerIds.length);
    }

    /**
     * @notice Kick the next deployable queue entry (metadata lockup elapsed or DeployReady resume).
     * @dev Permissionless; MarketInitializer rate-limits are replaced by this contract's cooldown
     *      and opens FinalConfig / runs the onchain deploy path in `_fulfillRequest`.
     */
    function processQueue() external rateLimited returns (bytes32 requestId) {
        requestId = _marketInitializer().deployAssets();
        emit Events.MarketDeployKicked(requestId);
    }

    // --------------------------------------------
    //  Transfers / Deactivations / Reactivations
    // --------------------------------------------

    /**
     * @notice Queue players for lifecycle review via `LifecycleManager`.
     * @dev Deployer-gated (HP multisig + EligibilityVerifier). LifecycleManager accepts
     *      this contract alone for `enqueueLifecycle`.
     */
    function queueChanges(
        bytes32[] calldata playerIds,
        LifecycleReason reason,
        uint32[] calldata effectiveMins
    ) external onlyDeployer {
        _lifecycleManager().queueChanges(playerIds, reason, effectiveMins);
        uint256 length = playerIds.length;
        for (uint256 i; i < length; ++i) {
            if (playerIds[i] == bytes32(0)) continue;
            emit Events.LifecycleEnqueued(playerIds[i], reason);
        }
    }

    /**
     * @notice Kick the next mature lifecycle entry (deactivate or LeagueTransfer oracle).
     * @dev Permissionless; cooldown shared with `processQueue`.
     */
    function processLifecycle() external rateLimited returns (bytes32 requestId) {
        requestId = _lifecycleManager().processLifecycle();
        emit Events.LifecycleProcessKicked(requestId);
    }
}
