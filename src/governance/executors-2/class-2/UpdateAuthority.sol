// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * Set as the UpdateAuthority admin role for general contract upkeep.
 * - Things that do not need protocol-level governance approval
 * - Things that are not purely data-driven, like in class-1 executors
 * 
 * Should be able to have a thin wrapper for a specific contract call.
 */