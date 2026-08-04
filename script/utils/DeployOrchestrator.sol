// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { Orchestrator } from "@src/Orchestrator.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";

/**
 * @title DeployOrchestrator
 * @notice Step 3: deploy Orchestrator and register `ORCHESTRATOR` on AddressProvider.
 * @dev Does not transfer AddressProvider ownership (see DeployHandoff).
 */
abstract contract DeployOrchestrator is AddressProviderOps {
    function _deployOrchestrator(address owner, address deployer) internal returns (address orchestrator) {
        if (owner == address(0)) revert("OWNER_ADDRESS required");
        if (deployer == address(0)) revert("deployer required");
        _requireAddressProvider();

        orchestrator = address(new Orchestrator(owner));
        _registerName(deployer, Keys.ORCHESTRATOR, orchestrator);

        console.log("=== DeployOrchestrator ===");
        console.log("Orchestrator", orchestrator);
        console.log("owner", owner);
    }
}
