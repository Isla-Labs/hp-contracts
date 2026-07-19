// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * Two completely different flows live in this contract:
 *
 * 1) Initial market deployment (gated)
 *    - Requires zk proof of eligibility (trustlessEligibility).
 *    - Held behind a timelock / DelayedBatchExecutor schedule path.
 *    - Creates the bonding market only — no VaultSet / AdvancedTradeSet yet.
 *
 * 2) Bonding → graduated (public / permissionless)
 *    - No zk proof. Readiness is onchain Doppler state (tick vs farTick / PoolStatus).
 *    - Offchain runners scan PlayerSetRegistry for status == BONDING, then call below.
 *    - Anyone may call; checks revert if the market is not ready or already processed.
 *
 * Scanner (offchain):
 * - Enumerate PlayerSetRegistry players with PlayerStatus.BONDING.
 * - For each: read DopplerHookInitializer.getState(token) + PoolManager.slot0.
 * - If already Graduated on Doppler → finalizeGraduatedMarket.
 * - If not graduated but tick has crossed farTick → migrateAndFinalizeMarket.
 * - Else skip until next scan.
 */
contract DeployDoppler {
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
     * (tick has crossed farTick; Doppler status still Initialized or Locked):
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
     * Access: public — no role. Reverts if tick has not crossed farTick,
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
