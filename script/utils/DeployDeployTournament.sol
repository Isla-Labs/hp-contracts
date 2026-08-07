// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { Orchestrator } from "@governance/Orchestrator.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";
import { ProxyUtils } from "./ProxyUtils.sol";

/**
 * @title DeployDeployTournament
 * @notice DeployTournament InitGuard proxy + AP register + Orchestrator authorize.
 * @dev Does not initialize — factories must be on AddressProvider first.
 *      `DeployFactories` upgrades the proxy and calls `initialize()` (owner → Orchestrator).
 */
abstract contract DeployDeployTournament is AddressProviderOps, ProxyUtils {
    struct DeployTournamentDeployment {
        address deployTournament;
        address initGuard;
    }

    function _deployDeployTournament(
        address owner,
        address deployer
    ) internal returns (DeployTournamentDeployment memory d) {
        if (owner == address(0)) revert("OWNER_ADDRESS required");
        if (deployer == address(0)) revert("deployer required");

        _requireAddressProvider();
        address orchestrator = _requireName(Keys.ORCHESTRATOR);
        _requireName(Keys.TOURNAMENT_REGISTRY);
        _requireName(Keys.PLAYER_SET_REGISTRY);

        InitGuard guard = new InitGuard();
        d.initGuard = address(guard);

        d.deployTournament = _deployInitGuardProxy(guard, deployer);

        _registerName(deployer, Keys.DEPLOY_TOURNAMENT, d.deployTournament);

        if (deployer == owner) {
            Orchestrator(orchestrator).addAuthorizedContract(d.deployTournament);
        } else {
            console.log("OWNER != deployer: grant DeployTournament AUTHORIZED_CONTRACT on Orchestrator");
        }

        console.log("=== DeployDeployTournament (proxy; init deferred to factories) ===");
        console.log("DeployTournament (proxy)", d.deployTournament);
    }
}
