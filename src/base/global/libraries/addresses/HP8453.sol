// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";

library HP8543 {
    //  Aragon Multisig
    address internal constant DAO = 0x0000000000000000000000000000000000000000;

    //  Intra-repo access control (cat-1, cat-2, cat-3)
    address internal constant CONSTITUTIONAL_TIMELOCK = 0x0000000000000000000000000000000000000000;
    address internal constant MAINTENANCE_TIMELOCK = 0x0000000000000000000000000000000000000000;
    address internal constant AUTOMATOR = 0x0000000000000000000000000000000000000000;

    //  Registries
    address internal constant TOURNAMENT_REGISTRY = 0x0000000000000000000000000000000000000000;
    address internal constant PLAYER_SET_REGISTRY = 0x0000000000000000000000000000000000000000;

    //  Lockers
    address internal constant DOPPLER_LOCKER = 0x0000000000000000000000000000000000000000;
    address internal constant TRANSFER_LOCKER = 0x0000000000000000000000000000000000000000;
    address internal constant CREATE_TOURNAMENT = 0x0000000000000000000000000000000000000000;

    //  Factories
    address internal constant PBR_FEE_HUB_FACTORY = 0x0000000000000000000000000000000000000000;
    address internal constant FEE_ROUTER_FACTORY = 0x0000000000000000000000000000000000000000;
    address internal constant PBR_TREASURY_FACTORY = 0x0000000000000000000000000000000000000000;
    address internal constant PLAYER_VAULT_FACTORY = 0x0000000000000000000000000000000000000000;

    //  Data
    address internal constant ELIGIBILITY_VERIFIER = 0x0000000000000000000000000000000000000000;
    address internal constant PPM_VERIFIER = 0x0000000000000000000000000000000000000000;
    address internal constant ROUND_MANAGER = 0x0000000000000000000000000000000000000000;

    // Chainlink Runtime Environment
    address internal constant CRE_FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;

    //  Doppler
    address internal constant DOPPLER_AIRLOCK = 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12;
    address internal constant DN404_FACTORY = 0x0000000000000000000000000000000000000000; // missing
    address internal constant NO_OP_GOVERNANCE_FACTORY = 0xe7dfbd5b0A2C3B4464653A9beCdc489229eF090E;
    address internal constant DOPPLER_HOOK_INITIALIZER = 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544;
    address internal constant REHYPE_DOPPLER_HOOK_INITIALIZER = 0x9982538F41f2ae29ddb9d3D9307010052984FDbB;
    address internal constant DOPPLER_HOOK_MIGRATOR = 0x1E40b0875DDa35f41E15cFB475403859B8c860c4;
    address internal constant REHYPE_DOPPLER_HOOK_MIGRATOR = 0x975f9d1939cf6e4A3c9D99f9d41e6411CF4dA23b;
    address internal constant NUMERAIRE = 0x0000000000000000000000000000000000000000;
    address internal constant INTEGRATOR = DAO;

    /// @dev Airlock Ownable owner — resolved at call time (not a compile-time constant).
    function airlockOwner() internal view returns (address) {
        return Ownable(DOPPLER_AIRLOCK).owner();
    }
}
