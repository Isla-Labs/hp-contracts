// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DeployCore } from "../utils/DeployCore.sol";
import { DeployFactories } from "../utils/DeployFactories.sol";
import { DeployData } from "../utils/DeployData.sol";

/// @notice Base mainnet — core stack (access, lockers, DeployTournament, registries).
contract DeployCoreStack is DeployCore {
    function run() external returns (CoreDeployment memory d) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address dao = vm.envAddress("DAO_ADDRESS");

        vm.startBroadcast(privateKey);
        d = _deployCore(dao, deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base mainnet — market / vault factories + DeployTournament.configureFactories.
contract DeployFactoriesStack is DeployFactories {
    function run() external returns (FactoryDeployment memory f) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        f = _deployFactories(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base mainnet — eligibility + matchweeks (+ ppm placeholder).
contract DeployDataStack is DeployData {
    function run() external returns (DataDeployment memory d) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        d = _deployData(deployer);
        vm.stopBroadcast();
    }
}
