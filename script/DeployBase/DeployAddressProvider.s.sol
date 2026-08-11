// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Script, console2 as console } from "forge-std/Script.sol";

import { AddressProvider } from "@src/AddressProvider.sol";

/**
 * @title DeployAddressProvider
 * @notice Standalone bootstrap: deploy the canonical address book only.
 * @dev Temporary `DEFAULT_ADMIN_ROLE` = deployer so sequential deploy steps can `setName`
 *      until a later `transferDefaultAdmin(ConstitutionalTimelock)`. Paste the logged
 *      address into `.env` as `ADDRESS_PROVIDER` (sole env address pointer).
 *
 *      Makefile:
 *        `make deploy-base-address-provider`
 *        `make deploy-base-sepolia-address-provider`
 *
 *      Env: PRIVATE_KEY
 */
contract DeployAddressProvider is Script {
    function run() external returns (address addressProvider) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        addressProvider = address(new AddressProvider(deployer));
        vm.stopBroadcast();

        console.log("=== paste into .env ===");
        console.log("ADDRESS_PROVIDER", addressProvider);
        console.log("DEFAULT_ADMIN (temporary deployer)", deployer);
        console.log("Next: make deploy-*-orchestrator (then registries, DT, data, lockers, factories, handoff)");
    }
}
