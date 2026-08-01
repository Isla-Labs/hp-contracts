// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Script, console2 } from "forge-std/Script.sol";

import { CvmCoordinator } from "@src/oracle/CvmCoordinator.sol";
import { CvmRouter } from "@src/oracle/CvmRouter.sol";
import { AutomataAttestationVerifier } from "@src/oracle/attestation/AutomataAttestationVerifier.sol";
import { MockAttestationVerifier } from "@src/oracle/attestation/MockAttestationVerifier.sol";
import { CvmRouterConfig } from "@types/oracle/CvmTypes.sol";
import { HP85432 } from "@addresses/HP84532.sol";
import { MockDstackApp } from "../../test/oracle/mocks/MockDstackApp.sol";

/**
 * @title DeployOracle
 * @notice Base Sepolia bootstrap for CVM oracle bus + registry.
 * @dev Env:
 *        PRIVATE_KEY            — deployer (defaults to DAO / CATEGORY_ONE)
 *        DAO_ADDRESS            — optional admin
 *        CONSTITUTIONAL_ADDRESS — optional cat-1
 *        USE_MOCK_VERIFIER      — default true (Sepolia staging)
 *        REGISTRATION_TTL       — default 7 days
 *        MAX_QUOTE_AGE          — default 1 hour
 *        COMPOSE_HASH           — optional bytes32 to allowlist immediately
 *
 *      Writes `deployments/base-sepolia-oracle.json`.
 */
contract DeployOracle is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address dao = vm.envOr("DAO_ADDRESS", deployer);
        address constitutional = vm.envOr("CONSTITUTIONAL_ADDRESS", deployer);

        bool useMock = vm.envOr("USE_MOCK_VERIFIER", true);
        uint64 ttl = uint64(vm.envOr("REGISTRATION_TTL", uint256(7 days)));
        uint64 maxQuoteAge = uint64(vm.envOr("MAX_QUOTE_AGE", uint256(1 hours)));

        vm.startBroadcast(privateKey);

        MockDstackApp dstack = new MockDstackApp(deployer);

        address verifier;
        if (useMock) {
            verifier = address(new MockAttestationVerifier(maxQuoteAge));
        } else {
            verifier =
                address(new AutomataAttestationVerifier(HP85432.AUTOMATA_DCAP_ATTESTATION, maxQuoteAge));
        }

        CvmCoordinator coordinator =
            new CvmCoordinator(dao, constitutional, address(0), verifier, ttl);

        dstack.transferOwnership(address(coordinator));

        if (dao == deployer) {
            coordinator.setDstackApp(address(dstack));
            if (vm.envExists("COMPOSE_HASH")) {
                coordinator.addComposeHash(vm.envBytes32("COMPOSE_HASH"));
            }
        } else {
            console2.log("DAO != deployer: call setDstackApp (+ addComposeHash) from DAO");
        }

        CvmRouterConfig memory routerConfig = CvmRouterConfig({
            maxCallbackGasLimit: 500_000,
            requestTimeout: uint32(1 days),
            gasForCallExactCheck: 5_000
        });
        CvmRouter router = new CvmRouter(dao, constitutional, address(coordinator), routerConfig);

        vm.stopBroadcast();

        console2.log("MockDstackApp", address(dstack));
        console2.log("AttestationVerifier", verifier);
        console2.log("CvmCoordinator", address(coordinator));
        console2.log("CvmRouter", address(router));
        console2.log("useMockVerifier", useMock);

        string memory json = string.concat(
            "{\n",
            '  "chainId": 84532,\n',
            '  "dstackApp": "',
            vm.toString(address(dstack)),
            '",\n',
            '  "attestationVerifier": "',
            vm.toString(verifier),
            '",\n',
            '  "cvmCoordinator": "',
            vm.toString(address(coordinator)),
            '",\n',
            '  "cvmRouter": "',
            vm.toString(address(router)),
            '",\n',
            '  "useMockVerifier": ',
            useMock ? "true" : "false",
            ",\n",
            '  "registrationTtl": ',
            vm.toString(uint256(ttl)),
            "\n}\n"
        );
        vm.writeFile("deployments/base-sepolia-oracle.json", json);
    }
}
