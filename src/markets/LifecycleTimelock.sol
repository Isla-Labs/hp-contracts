// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/* 
 * 1. Scan api.highpotential.io/eligibility to get the latest deployments and discontinuations
 * 2. Return asset data to the caller (prepare Doppler deployment, prepare Timelock interaction)
 * __
 *
 * 3. Scan pools to get latest bonding curve statuses
 * 4. Call airlock.migrate() if the pool is ready for graduation 
 * 
 */