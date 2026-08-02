// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Script } from "forge-std/Script.sol";

/**
 * @notice Read / patch `deployments/base-sepolia-oracle.json` from forge scripts.
 */
abstract contract OracleDeployment is Script {
    string internal constant ORACLE_DEPLOYMENT_PATH = "deployments/base-sepolia-oracle.json";

    function _readOracleDeployment() internal view returns (string memory json) {
        json = vm.readFile(ORACLE_DEPLOYMENT_PATH);
    }

    function _oracleCoordinator(string memory json) internal pure returns (address) {
        return vm.parseJsonAddress(json, ".cvmCoordinator");
    }

    function _oracleRouter(string memory json) internal pure returns (address) {
        return vm.parseJsonAddress(json, ".cvmRouter");
    }

    function _writeOracleImpl(string memory key, address impl) internal {
        vm.writeJson(string.concat('"', vm.toString(impl), '"'), ORACLE_DEPLOYMENT_PATH, string.concat(".", key));
    }
}
