// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Script, console2 } from "forge-std/Script.sol";

import { TestData } from "@src/data/test/TestData.sol";

/**
 * @title DeployTestData
 * @notice Deploy the Sepolia `TestData` consumer against the live `CvmRouter`.
 * @dev Makefile: `make deploy-base-sepolia-test-data`
 *
 *      Env:
 *        PRIVATE_KEY
 *        CVM_ROUTER — from Make / deployments/base-sepolia-oracle.json
 *        FULFILL_GAS_LIMIT — default 300000
 *
 *      Writes `deployments/base-sepolia-test-data.json`.
 */
contract DeployTestData is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address router = vm.envAddress("CVM_ROUTER");
        uint32 fulfillGas = uint32(vm.envOr("FULFILL_GAS_LIMIT", uint256(300_000)));

        vm.startBroadcast(privateKey);
        TestData testData = new TestData(router, fulfillGas);
        vm.stopBroadcast();

        console2.log("TestData", address(testData));
        console2.log("CvmRouter", router);
        console2.log("fulfillGasLimit", fulfillGas);

        string memory json = string.concat(
            "{\n",
            '  "chainId": 84532,\n',
            '  "testData": "',
            vm.toString(address(testData)),
            '",\n',
            '  "cvmRouter": "',
            vm.toString(router),
            '",\n',
            '  "job": "TestFetch",\n',
            '  "fulfillGasLimit": ',
            vm.toString(uint256(fulfillGas)),
            "\n}\n"
        );
        vm.writeFile("deployments/base-sepolia-test-data.json", json);
    }
}
