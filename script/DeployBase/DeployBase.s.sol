// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DeployCore } from "../utils/DeployCore.sol";
import { DeployFactories } from "../utils/DeployFactories.sol";

/// @notice Base mainnet — core stack (Orchestrator, lockers, registries).
contract DeployCoreStack is DeployCore {
    function run() external returns (CoreDeployment memory d) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address owner = vm.envOr("OWNER_ADDRESS", vm.envAddress("DAO_ADDRESS"));

        address cvmRouter = vm.envAddress("CVM_ROUTER");

        vm.startBroadcast(privateKey);
        d = _deployCore(owner, deployer, cvmRouter);
        vm.stopBroadcast();
    }
}

/// @notice Base mainnet — market / vault factories + Orchestrator.configureFactories.
contract DeployFactoriesStack is DeployFactories {
    function run() external returns (FactoryDeployment memory f) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        f = _deployFactories(deployer);
        vm.stopBroadcast();
    }
}
