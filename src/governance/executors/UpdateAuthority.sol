// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DelayedBatchExecutor } from "@governance/core/DelayedBatchExecutor.sol";

/**
 * @title UpdateAuthority
 * @notice Catch-all ADMIN / UPDATE paths that are not lifecycle or tournament bundles.
 * @dev Set as `ADMIN_ROLE` / `UPDATE_ROLE` where AccessControl is used and a multisig would
 *      otherwise have been used directly. Multisig proposes into this executor (DAO grants
 *      `PROPOSER_ROLE`). Later keepers may propose purely onchain-predicate updates.
 *
 *      Examples:
 *      - Scan bonding curves ready for Doppler migration → migrate + PlayerSetRegistry.setDopplerData
 *      - Repair registry if migrate landed but PlayerSetRegistry lagged
 *      - FeeRouter.setAtFunding and similar non-upgrade parameter tweaks
 *      - Token rescue (prefer Multisig → DAO.execute for audit clarity on sensitive rescues)
 *
 *      **Not** for beacon/proxy upgrades or vkey rotation — those go through
 *      `ConstitutionalTimelock` (Class 3).
 *
 *      Entry points inherited: `schedule`, `execute`, `cancel`.
 */
contract UpdateAuthority is DelayedBatchExecutor {
    uint256 public constant DEFAULT_MIN_DELAY = 1 days;

    constructor(address admin_) DelayedBatchExecutor(admin_, DEFAULT_MIN_DELAY) {}
}
