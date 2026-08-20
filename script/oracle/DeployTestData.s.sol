// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Script, console2 } from "forge-std/Script.sol";

import { TestData } from "@oracle/test/TestData.sol";
import { CvmRouter } from "@src/oracle/CvmRouter.sol";

/**
 * @title DeployTestData
 * @notice Deploy the Sepolia `TestData` (`VanitySalts`) consumer against the live `CvmRouter`.
 * @dev Makefile: `make deploy-base-sepolia-test-data`
 *
 *      Env:
 *        PRIVATE_KEY — must own `CvmRouter` (allowlists this consumer via `setRequester`)
 *        CVM_ROUTER — from Make / deployments/base-sepolia-oracle.json
 *
 *      Writes `deployments/base-sepolia-test-data.json`.
 */
contract DeployTestData is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address router = vm.envAddress("CVM_ROUTER");

        vm.startBroadcast(privateKey);
        TestData testData = new TestData(router);
        CvmRouter(router).setRequester(address(testData), true);
        vm.stopBroadcast();

        console2.log("TestData", address(testData));
        console2.log("CvmRouter", router);

        string memory json = string.concat(
            "{\n",
            '  "chainId": 84532,\n',
            '  "testData": "',
            vm.toString(address(testData)),
            '",\n',
            '  "cvmRouter": "',
            vm.toString(router),
            '",\n',
            '  "job": "VanitySalts"\n',
            "}\n"
        );
        vm.writeFile("deployments/base-sepolia-test-data.json", json);
    }
}
