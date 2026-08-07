// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";

library HP85432 {
    // DAO addresses
    address internal constant HP_MULTISIG = 0x0D4034c1538d2435D99D2b953302e8374D15C432;
    address internal constant HP_TREASURY = 0x7Ca4d3C95b4A843aeD5C14e356973fCD400c5d00;

    //  Access
    address internal constant ORCHESTRATOR = 0x0000000000000000000000000000000000000000;
    address internal constant DEPLOY_TOURNAMENT = 0x0000000000000000000000000000000000000000;

    //  Registries
    address internal constant TOURNAMENT_REGISTRY = 0x0000000000000000000000000000000000000000;
    address internal constant PLAYER_SET_REGISTRY = 0x0000000000000000000000000000000000000000;

    //  Lockers
    address internal constant DOPPLER_LOCKER = 0x0000000000000000000000000000000000000000;
    address internal constant DOPPLER_CONFIG = 0x0000000000000000000000000000000000000000;
    address internal constant TRANSFER_LOCKER = 0x0000000000000000000000000000000000000000;
    address internal constant EXCESS_SUPPLY_LOCKER = 0x0000000000000000000000000000000000000000;

    //  Factories
    address internal constant PBR_FEE_HUB_FACTORY = 0x0000000000000000000000000000000000000000;
    address internal constant FEE_ROUTER_FACTORY = 0x0000000000000000000000000000000000000000;
    address internal constant PBR_TREASURY_FACTORY = 0x0000000000000000000000000000000000000000;
    address internal constant PLAYER_VAULT_FACTORY = 0x0000000000000000000000000000000000000000;

    //  Data
    address internal constant ELIGIBILITY_STORE = 0x0000000000000000000000000000000000000000;
    address internal constant ELIGIBILITY_VERIFIER = 0x0000000000000000000000000000000000000000;
    address internal constant PPM_VERIFIER = 0x0000000000000000000000000000000000000000;
    address internal constant PBR_SETTLE = 0x0000000000000000000000000000000000000000;
    address internal constant ROUND_MANAGER = 0x0000000000000000000000000000000000000000;

    // Chainlink Runtime Environment
    address internal constant CRE_FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;

    // Automata DCAP (TEE quote verification)
    address internal constant AUTOMATA_DCAP_ATTESTATION = 0xaDdeC7e85c2182202b66E331f2a4A0bBB2cEEa1F;
    address internal constant AUTOMATA_PCCS_ROUTER = 0xaf2a0D5473062b36E2dE986DA09d945EB26d492B;

    //  Doppler
    address internal constant DOPPLER_AIRLOCK = 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e;
    address internal constant DN404_FACTORY = 0x98b0Aa2e0f134dbB3eb157b5646D387E6D55243a;
    address internal constant NO_OP_GOVERNANCE_FACTORY = 0x7bD798fafC99A3b17E261F8308A8C11B56935ea1;
    address internal constant LAUNCHPAD_GOVERNANCE_FACTORY = 0x0902e7C7207df8ed6303Aef4382bcab181b5fBFA;
    address internal constant DOPPLER_HOOK_INITIALIZER = 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544;
    address internal constant REHYPE_DOPPLER_HOOK_INITIALIZER = 0x78C79C95eacEb2D08f7a55cc0D31012f8aF510c3;
    address internal constant DOPPLER_HOOK_MIGRATOR = 0x1E40b0875DDa35f41E15cFB475403859B8c860c4;
    address internal constant REHYPE_DOPPLER_HOOK_MIGRATOR = 0x9349E5A3e6458aa65E2fB7ED67e9aD08Ae7F660D;
    address internal constant NUMERAIRE = 0x0000000000000000000000000000000000000000;
    address internal constant INTEGRATOR = ORCHESTRATOR;

    /// @dev Airlock Ownable owner — resolved at call time (not a compile-time constant).
    function airlockOwner() internal view returns (address) {
        return Ownable(DOPPLER_AIRLOCK).owner();
    }
}
