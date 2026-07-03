// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DataProvider } from "../base/abstract/DataProvider.sol";
import { RateLimiter } from "../base/abstract/RateLimiter.sol";

/**
 * @title LifecycleTimelock
 * @author Isla Labs (Tom Jarvis | 0xBasti42)
 * @notice Manages the lifecycle of HP markets and the governance conventions for the Timelock.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract LifecycleTimelock is DataProvider, RateLimiter {

/* 
 * 1. Scan api.highpotential.io/eligibility to get the latest deployments and discontinuations
 * 2. Return asset data to the caller (prepare Doppler deployment, prepare Timelock interaction)
 * __
 *
 * 3. Scan pools to get latest bonding curve statuses
 * 4. Call airlock.migrate() if the pool is ready for graduation 
 * 
 */

// This is probably the wrong convention. Standard procedure is to have server => contract calls,
// with ready-made params. The server can just prepare the params and send them to the contract
// instead. Timelock is good, because it handles failure gracefully and introduces selective 
// transparency. Once the call arrives, we can include a Chainlink Functions verification step.
// Basically, re-call StatsPerform endpoints to check that the personUuid is eligible/ineligible.
// Perform this check again before deploying/discontinuing a pool.

}