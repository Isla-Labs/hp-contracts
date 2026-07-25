// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Canonical `AddressProvider` name keys (`keccak256(bytes(name))`).
/// @dev Keep in sync with `HP8453` / `HP84532` constant names.
library AddressKeys {
    // Governance
    string internal constant DAO = "DAO";
    string internal constant CONSTITUTIONAL_TIMELOCK = "CONSTITUTIONAL_TIMELOCK";
    string internal constant MAINTENANCE_TIMELOCK = "MAINTENANCE_TIMELOCK";
    string internal constant AUTOMATOR = "AUTOMATOR";
    string internal constant CREATE_TOURNAMENT = "CREATE_TOURNAMENT";

    // Registries
    string internal constant TOURNAMENT_REGISTRY = "TOURNAMENT_REGISTRY";
    string internal constant PLAYER_SET_REGISTRY = "PLAYER_SET_REGISTRY";
    string internal constant REFERRAL_REGISTRY = "REFERRAL_REGISTRY";

    // Lockers / data
    string internal constant DOPPLER_LOCKER = "DOPPLER_LOCKER";
    string internal constant TRANSFER_LOCKER = "TRANSFER_LOCKER";
    string internal constant PPM_VERIFIER = "PPM_VERIFIER";
    string internal constant CRE_FORWARDER = "CRE_FORWARDER";
}
