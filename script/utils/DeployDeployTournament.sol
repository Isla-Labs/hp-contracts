// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { DeployTournament } from "@deployments/tournaments/DeployTournament.sol";
import { Orchestrator } from "@governance/Orchestrator.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";

/**
 * @title DeployDeployTournament
 * @notice Immutable DeployTournament + AP register + Orchestrator authorize.
 * @dev Factories / registry resolve via AddressBook at call time (must be on AP before `deploy`).
 */
abstract contract DeployDeployTournament is AddressProviderOps {
    struct DeployTournamentDeployment {
        address deployTournament;
    }

    function _deployDeployTournament(
        address owner,
        address deployer
    ) internal returns (DeployTournamentDeployment memory d) {
        if (owner == address(0)) revert("OWNER_ADDRESS required");
        if (deployer == address(0)) revert("deployer required");

        address addressProvider = address(_requireAddressProvider());
        address orchestrator = _requireName(Keys.ORCHESTRATOR);
        _requireName(Keys.TOURNAMENT_REGISTRY);
        _requireName(Keys.PLAYER_SET_REGISTRY);

        d.deployTournament = address(new DeployTournament(addressProvider));

        _registerName(deployer, Keys.DEPLOY_TOURNAMENT, d.deployTournament);

        if (deployer == owner) {
            Orchestrator(orchestrator).addAuthorizedContract(d.deployTournament);
        } else {
            console.log("OWNER != deployer: grant DeployTournament AUTHORIZED_CONTRACT on Orchestrator");
        }

        console.log("=== DeployDeployTournament (immutable) ===");
        console.log("DeployTournament", d.deployTournament);
    }
}
