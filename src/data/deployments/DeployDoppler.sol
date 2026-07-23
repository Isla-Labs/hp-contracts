// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DeploymentsErrors as Errors } from "@base/global/libraries/errors/DeploymentsErrors.sol";
import { DeploymentsEvents as Events } from "@base/global/libraries/events/DeploymentsEvents.sol";
import { IDeployDoppler } from "@base/global/interfaces/data/IDeployDoppler.sol";
import { EligibilityBucket, EligibilityGroups } from "@src/data/eligibility/types/EligibilityTypes.sol";
import { DopplerConfig } from "@src/data/deployments/types/DopplerConfig.sol";
import { DopplerTypes } from "@src/data/deployments/types/DopplerTypes.sol";

/**
 * Two completely different flows live in this contract:
 *
 * 0) Eligibility waiting room (from EligibilityVerifier)
 *    - `enqueueEligible` stores cohort-tagged playerIds for later deploy formatting.
 *    - Only the configured `eligibilityVerifier` may write.
 *    - Consumes deploy cohorts only; `groups.toDiscontinue` is handled in EligibilityVerifier.
 *    - Name/symbol filled later (Chainlink Functions); see `DopplerTypes.PendingEligible`.
 *
 * 1) Initial market deployment (gated)
 *    - Requires zk proof of eligibility (trustlessEligibility).
 *    - Held behind a timelock / DelayedBatchExecutor schedule path.
 *    - Creates the bonding market only — no VaultSet / AdvancedTradeSet yet.
 *    - `Airlock.create` params assembled via `DopplerTypes.buildCreateParams(marketLaunchConfig())`.
 *
 * 2) Bonding → graduated (public / permissionless)
 *    - No zk proof. Readiness is onchain Doppler state (tick vs farTick / PoolStatus)
 *      OR HP soft path: raised ≥ `minGraduateProceeds` after `launch + minBondingDuration`.
 *    - Offchain runners scan PlayerSetRegistry for status == BONDING, then call below.
 *    - Anyone may call; checks revert if the market is not ready or already processed.
 *
 * Shared launch recipe is inherited from `DopplerConfig` (defaults in constructor;
 * `CATEGORY_ONE` may update without redeploying this stack).
 *
 * Scanner (offchain):
 * - Enumerate PlayerSetRegistry players with PlayerStatus.BONDING.
 * - For each: read DopplerHookInitializer.getState(token) + PoolManager.slot0.
 * - If already Graduated on Doppler → finalizeGraduatedMarket.
 * - If not graduated but tick has crossed farTick → migrateAndFinalizeMarket.
 * - Else if age ≥ minBondingDuration and proceeds ≥ minGraduateProceeds → migrateAndFinalizeMarket.
 * - Else skip until next scan.
 */
contract DeployDoppler is DopplerConfig, IDeployDoppler {
    // -------------------------------------------------------------------------
    //  Eligibility waiting room
    // -------------------------------------------------------------------------

    /// @notice Sole writer for `enqueueEligible` (set once after EligibilityVerifier deploy).
    address public eligibilityVerifier;

    DopplerTypes.PendingEligible[] private _pending;
    mapping(bytes32 playerId => bool) private _queued;

    /**
     * @param constitutionalTimelock_ `ConstitutionalTimelock` — `CATEGORY_ONE` (config overrides).
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE`.
     */
    constructor(address constitutionalTimelock_, address dao_) DopplerConfig(constitutionalTimelock_, dao_) { }

    /// @notice One-time wire from EligibilityVerifier → this waiting room.
    function setEligibilityVerifier(address eligibilityVerifier_) external {
        if (eligibilityVerifier != address(0)) revert Errors.AlreadySet();
        if (eligibilityVerifier_ == address(0)) revert Errors.ZeroAddress();
        eligibilityVerifier = eligibilityVerifier_;
        emit Events.EligibilityVerifierSet(eligibilityVerifier_);
    }

    /// @inheritdoc IDeployDoppler
    function enqueueEligible(EligibilityGroups calldata groups) external {
        if (msg.sender != eligibilityVerifier) revert Errors.Unauthorized();

        uint256 added;
        added += _enqueueCohort(groups.goalkeepers, EligibilityBucket.Goalkeeper);
        added += _enqueueCohort(groups.under21, EligibilityBucket.Under21);
        added += _enqueueCohort(groups.outfield, EligibilityBucket.Outfield);
        added += _enqueueCohort(groups.newTransfers, EligibilityBucket.NewTransfer);

        emit Events.EligiblePlayersEnqueued(added, _pending.length);
    }

    function pendingCount() external view returns (uint256) {
        return _pending.length;
    }

    function isQueued(bytes32 playerId) external view returns (bool) {
        return _queued[playerId];
    }

    /// @notice Page pending waiting-room entries (independent of EligibilityVerifier storage).
    function pendingEligible(uint256 offset, uint256 limit)
        external
        view
        returns (DopplerTypes.PendingEligible[] memory out)
    {
        uint256 total = _pending.length;
        if (offset >= total || limit == 0) {
            return new DopplerTypes.PendingEligible[](0);
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

        uint256 n = end - offset;
        out = new DopplerTypes.PendingEligible[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = _pending[offset + i];
        }
    }

    function _enqueueCohort(bytes32[] calldata playerIds, EligibilityBucket bucket)
        private
        returns (uint256 added)
    {
        uint256 length = playerIds.length;
        for (uint256 i; i < length; ++i) {
            bytes32 playerId = playerIds[i];
            if (playerId == bytes32(0) || _queued[playerId]) continue;

            _queued[playerId] = true;
            _pending.push(
                DopplerTypes.PendingEligible({
                    playerId: playerId,
                    bucket: bucket,
                    name: "",
                    symbol: "",
                    metadataSet: false
                })
            );
            unchecked {
                ++added;
            }
        }
    }

    // -------------------------------------------------------------------------
    //  1) Initial deployment — zk + timelock (NOT public)
    // -------------------------------------------------------------------------

    /**
     * After zk proof (eligibility) + timelock delay elapsed:
     * - Deploy Doppler bonding market via Airlock
     *     (DopplerHookInitializer + RehypeDopplerHookInitializer as dopplerHook).
     * - Deploy FeeRouter for the player; wire league / pbrFeeHub.
     * - Add TokenData, DopplerData, and TournamentData to PlayerSetRegistry
     *     (PlayerSetRegistry.addPlayerSet → status = BONDING).
     * - Do NOT deploy VaultSet or AdvancedTradeSet here.
     *
     * Access: PROPOSER schedules after proof verify; execute after minDelay.
     *         (Or executeWithProof once the eligibility verifier is wired.)
     */
    function deployBondingMarket(/* playerId, eligibilityProof, publicInputs, deployParams */) external {
        // gated: zk + timelock
        // use marketLaunchConfig() + DopplerTypes.buildCreateParams(...)
    }

    // -------------------------------------------------------------------------
    //  2) Graduation / finalize — public, keeper-callable
    // -------------------------------------------------------------------------

    /**
     * If bonding market has already graduated on Doppler
     * (DopplerHookInitializer status == Graduated):
     * - Require PlayerSetRegistry status == BONDING (idempotency guard).
     * - Deploy VaultSet (PlayerVault + stToken).
     * - Deploy AdvancedTradeSet (advancedTradeVault + markSource stubs ok).
     * - Register vault on each relevant PBRTreasury vaultRegistry.
     * - PlayerSetRegistry.addVaultData + addAdvancedTradeData.
     * - PlayerSetRegistry.setDopplerData if activePool / hooks need post-grad update.
     * - PlayerSetRegistry.setStatus(playerId, GRADUATED).
     *
     * Access: public — no role. Reverts if Doppler status is not Graduated,
     *         or if HP registry is not still BONDING / vaults already set.
     */
    function finalizeGraduatedMarket(/* playerId */) internal {
        // public
    }

    /**
     * If bonding market has not graduated but is ready to
     * (tick has crossed farTick; Doppler status still Initialized or Locked)
     * OR HP soft path (age ≥ minBondingDuration and proceeds ≥ minGraduateProceeds):
     * - Require PlayerSetRegistry status == BONDING.
     * - If Locked + graduation hook path: call DopplerHookInitializer.graduate(token)
     *     when required by config, then proceed.
     * - If Initialized (migrate path): call Airlock.migrate(token)
     *     → exitLiquidity → DopplerHookMigrator + RehypeDopplerHookMigrator pool.
     * - Then same finalize bundle as finalizeGraduatedMarket:
     *     deploy VaultSet + AdvancedTradeSet, wire treasuries,
     *     update PlayerSetRegistry (vault / AT / doppler data),
     *     setStatus(GRADUATED).
     *
     * Access: public — no role. Reverts if neither farTick nor soft path is satisfied,
     *         if already Exited/Graduated incorrectly for this branch,
     *         or if HP registry is not still BONDING.
     *
     * Note: Airlock.migrate is itself permissionless; this wrapper additionally
     *       performs the HP-side VaultSet / registry updates atomically after migrate.
     */
    function migrateAndFinalizeMarket(/* playerId */) internal {
        // public
    }

    // -------------------------------------------------------------------------
    //  Optional: single entry for runners
    // -------------------------------------------------------------------------

    /**
     * Convenience for offchain runners:
     * - If Doppler status == Graduated → finalizeGraduatedMarket.
     * - Else if ready to migrate (tick vs farTick) → migrateAndFinalizeMarket.
     * - Else if soft path (30d + ≥50 ETH defaults) → migrateAndFinalizeMarket.
     * - Else revert NotReady.
     *
     * Access: public — no role.
     */
    function tryFinalizeMarket(/* playerId */) external {
        // check bonding status against registry status
        // if mismatch, deploy VaultSet and AdvancedTradeSet, and update registry
        // if bonding curve is ready but not migrated yet, migrate then deploy and update
        //
        // Note: this is an important distinction because the migrate function on Doppler curves
        // is public by default, so there is potential for mismatches. This runner can help to
        // reduce any gaps while maintaining data integrity.
        //
        // Note Note: it might be best to recursively check all markets that have a BONDING status.
        // Then, prep the data and move into local storage for the next phase:
        // - Deploy VaultSet
        // - Deploy AdvancedTradeSet
        // - Update PBRTreasury for each tournament in the player's activeTournaments list
        // - Update Registry
    }
}
