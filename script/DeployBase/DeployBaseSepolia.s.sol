// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DeployCore } from "../utils/DeployCore.sol";
import { DeployFactories } from "../utils/DeployFactories.sol";

/// @notice Base Sepolia — core stack.
contract DeployCoreStack is DeployCore {
    function run() external returns (CoreDeployment memory d) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address owner = vm.envOr("OWNER_ADDRESS", vm.envOr("DAO_ADDRESS", deployer));

        vm.startBroadcast(privateKey);
        d = _deployCore(owner, deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base Sepolia — market / vault factories.
contract DeployFactoriesStack is DeployFactories {
    function run() external returns (FactoryDeployment memory f) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        // DeployFactories reads OWNER_ADDRESS — default to deployer for solo bootstraps.
        if (!vm.envExists("OWNER_ADDRESS") && !vm.envExists("DAO_ADDRESS")) {
            vm.setEnv("OWNER_ADDRESS", vm.toString(deployer));
        }

        vm.startBroadcast(privateKey);
        f = _deployFactories(deployer);
        vm.stopBroadcast();
    }
}
