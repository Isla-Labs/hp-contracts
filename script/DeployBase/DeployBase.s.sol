// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DeployCore } from "../utils/DeployCore.sol";

/// @notice Base mainnet core deployment.
contract DeployAll is DeployCore {
    function run() external returns (CoreDeployment memory d) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address dao = vm.envAddress("DAO_ADDRESS");

        vm.startBroadcast(privateKey);
        d = _deployCore(dao, deployer);
        vm.stopBroadcast();
    }
}

/// @notice Alias for Makefile / incremental targets.
contract DeployCoreStack is DeployAll { }
