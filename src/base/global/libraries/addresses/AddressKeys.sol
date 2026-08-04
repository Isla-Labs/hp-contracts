// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Canonical `AddressProvider` name keys (`keccak256(bytes(name))`).
/// @dev Keep in sync with `HP8453` / `HP84532` constant names.
library AddressKeys {
    // Access
    string internal constant ORCHESTRATOR = "ORCHESTRATOR";
    string internal constant DEPLOY_TOURNAMENT = "DEPLOY_TOURNAMENT";

    // Registries
    string internal constant TOURNAMENT_REGISTRY = "TOURNAMENT_REGISTRY";
    string internal constant PLAYER_SET_REGISTRY = "PLAYER_SET_REGISTRY";
    string internal constant REFERRAL_REGISTRY = "REFERRAL_REGISTRY";

    // Lockers / data
    string internal constant DOPPLER_LOCKER = "DOPPLER_LOCKER";
    string internal constant TRANSFER_LOCKER = "TRANSFER_LOCKER";
    string internal constant ELIGIBILITY_STORE = "ELIGIBILITY_STORE";
    string internal constant ELIGIBILITY_VERIFIER = "ELIGIBILITY_VERIFIER";
    string internal constant PPM_VERIFIER = "PPM_VERIFIER";
    string internal constant CRE_FORWARDER = "CRE_FORWARDER";
    string internal constant PBR_SETTLE = "PBR_SETTLE";
    string internal constant ROUND_MANAGER = "ROUND_MANAGER";

    // Factories
    string internal constant FEE_ROUTER_FACTORY = "FEE_ROUTER_FACTORY";
    string internal constant PBR_FEE_HUB_FACTORY = "PBR_FEE_HUB_FACTORY";
    string internal constant PBR_TREASURY_FACTORY = "PBR_TREASURY_FACTORY";
    string internal constant PLAYER_VAULT_FACTORY = "PLAYER_VAULT_FACTORY";

    // Automata DCAP (TEE quote verification)
    string internal constant AUTOMATA_DCAP_ATTESTATION = "AUTOMATA_DCAP_ATTESTATION";
    string internal constant AUTOMATA_PCCS_ROUTER = "AUTOMATA_PCCS_ROUTER";

    // CVM oracle bus
    string internal constant CVM_COORDINATOR = "CVM_COORDINATOR";
    string internal constant CVM_ROUTER = "CVM_ROUTER";
}
