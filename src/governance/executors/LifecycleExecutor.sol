// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DelayedBatchExecutor } from "@governance/core/DelayedBatchExecutor.sol";

/**
 * @title LifecycleExecutor
 * @notice Player market lifecycle bundles (deploy, league transfer, discontinuation).
 * @dev Holds `LIFECYCLE_ROLE` / `UPDATE_ROLE` on `PlayerSetRegistry`, `FeeRouter`, vaults, treasuries.
 *
 *      Decision class:
 *      - **Deploy / discontinue (target):** Class 1 — `executeWithProof` once eligibility /
 *        discontinuation guests (`trustlessEligibility.md`) are wired via `setProofVerifier`.
 *      - **Transitional / product overrides:** Class 2 — grant `PROPOSER_ROLE` to a Multisig-
 *        driven path (DAO.execute → `schedule`).
 *
 *      Suggested delays: deploy 0–24h; discontinue 48h–7d (+ optional council cancel).
 *
 *      Atomic bundles this executor is responsible for (typed helpers TBD once factories land):
 *
 *      **Player created**
 *      - Deploy Doppler market (standard params)
 *      - Deploy FeeRouter; set league / pbrFeeHub
 *      - Deploy PlayerVault; set active tournaments
 *      - Register vault on each relevant PBRTreasury vaultRegistry
 *      - Deploy advancedTradeVault + markSource stubs
 *      - Register PlayerSet in PlayerSetRegistry (+ AssetRegistry leaf at MarketFactory)
 *
 *      **Player moves league**
 *      - FeeRouter.setPbrFeeHub
 *      - Remove vault from old league treasuries; add to new
 *      - PlayerSetRegistry.setLeagueId
 *
 *      **Player unsupported / discontinued**
 *      - Clear FeeRouter hub / delist
 *      - Remove vaults from treasuries
 *      - Set PlayerVault inactive (withdraw-only)
 *
 *      Doppler *migration* when curve-ready is NOT owned here — see `UpdateAuthority`.
 *
 *      Entry points inherited: `schedule`, `execute`, `executeWithProof`, `cancel`.
 */
contract LifecycleExecutor is DelayedBatchExecutor {
    /// @notice Default ops delay for transitional (non-proof) lifecycle schedules
    uint256 public constant DEFAULT_MIN_DELAY = 1 days;

    constructor(address admin_) DelayedBatchExecutor(admin_, DEFAULT_MIN_DELAY) {}
}
