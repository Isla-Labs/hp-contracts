// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * Has permission to update miscellaneous data in different contracts.
 * Set as ADMIN_ROLE where AccessControl is used, and where the multisig would have been used.
 * Multisig can then propose updates into this timelock. Governance can be changed to token-gated.
 * 
 * e.g.
 * - Scans bonding curve pools to see if they are ready for migration, and 
 *   migrates / updates PlayerSetRegistry.
 * - If a bonding curve has been updated but PlayerSetRegistry is not yet updated, updates
 *   PlayerSetRegistry.
 */
