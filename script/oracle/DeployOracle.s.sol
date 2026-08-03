// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Script, console2 } from "forge-std/Script.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { CvmCoordinator } from "@src/oracle/CvmCoordinator.sol";
import { CvmRouter } from "@src/oracle/CvmRouter.sol";
import { AutomataAttestationVerifier } from "@src/oracle/attestation/AutomataAttestationVerifier.sol";
import { MockAttestationVerifier } from "@src/oracle/attestation/MockAttestationVerifier.sol";
import { CvmRouterConfig } from "@types/oracle/CvmTypes.sol";
import { HP85432 } from "@addresses/HP84532.sol";

import { ProxyUtils } from "../utils/ProxyUtils.sol";

/**
 * @title DeployOracle
 * @notice Base Sepolia bootstrap: upgradeable CvmCoordinator + CvmRouter (Transparent proxies).
 * @dev Hybrid: Phala DstackApp/KMS on Ethereum (out of band). This stack is attestation registry
 *      + request bus only — stable proxy addresses so CVM sealed env need not change on upgrades.
 *
 *      ProxyAdmin owner = DAO/deployer initially.
 *
 *      Makefile: `make deploy-base-sepolia-oracle`
 *
 *      Env:
 *        PRIVATE_KEY, DAO_ADDRESS, CONSTITUTIONAL_ADDRESS
 *        USE_MOCK_VERIFIER (default false — Automata DCAP; set true for local/unit bring-up)
 *        REGISTRATION_TTL (default 1 day)
 *        MAX_QUOTE_AGE (default 1 hour)
 *        COMPOSE_HASH (optional immediate allowlist)
 */
contract DeployOracle is Script, ProxyUtils {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address dao = vm.envOr("DAO_ADDRESS", deployer);
        address constitutional = vm.envOr("CONSTITUTIONAL_ADDRESS", deployer);

        bool useMock = vm.envOr("USE_MOCK_VERIFIER", false);
        uint64 ttl = uint64(vm.envOr("REGISTRATION_TTL", uint256(1 days)));
        uint64 maxQuoteAge = uint64(vm.envOr("MAX_QUOTE_AGE", uint256(1 hours)));

        vm.startBroadcast(privateKey);

        InitGuard guard = new InitGuard();

        address verifier;
        if (useMock) {
            verifier = address(new MockAttestationVerifier(maxQuoteAge));
        } else {
            verifier = address(new AutomataAttestationVerifier(HP85432.AUTOMATA_DCAP_ATTESTATION, maxQuoteAge));
        }

        address coordinatorProxy = _deployInitGuardProxy(guard, dao);
        address coordinatorImpl = address(new CvmCoordinator());
        _upgradeAndCall(
            coordinatorProxy,
            coordinatorImpl,
            abi.encodeCall(CvmCoordinator.initialize, (dao, verifier, ttl))
        );

        if (dao == deployer && vm.envExists("COMPOSE_HASH")) {
            CvmCoordinator(coordinatorProxy).addComposeHash(vm.envBytes32("COMPOSE_HASH"));
        }

        CvmRouterConfig memory routerConfig = CvmRouterConfig({
            // Headroom for one-club squad upserts (Base per-tx cap ~16.7M; raise later if needed).
            maxCallbackGasLimit: 5_000_000,
            requestTimeout: uint32(1 hours),
            gasForCallExactCheck: 5000
        });

        address routerProxy = _deployInitGuardProxy(guard, dao);
        address routerImpl = address(new CvmRouter());
        _upgradeAndCall(
            routerProxy,
            routerImpl,
            abi.encodeCall(CvmRouter.initialize, (dao, constitutional, coordinatorProxy, routerConfig))
        );

        vm.stopBroadcast();

        console2.log("InitGuard", address(guard));
        console2.log("AttestationVerifier", verifier);
        console2.log("CvmCoordinator proxy", coordinatorProxy);
        console2.log("CvmCoordinator impl", coordinatorImpl);
        console2.log("CvmRouter proxy", routerProxy);
        console2.log("CvmRouter impl", routerImpl);
        console2.log("ProxyAdmin owner", dao);
        console2.log("useMockVerifier", useMock);

        string memory json = string.concat(
            "{\n",
            '  "chainId": 84532,\n',
            '  "attestationVerifier": "',
            vm.toString(verifier),
            '",\n',
            '  "cvmCoordinator": "',
            vm.toString(coordinatorProxy),
            '",\n',
            '  "cvmCoordinatorImpl": "',
            vm.toString(coordinatorImpl),
            '",\n',
            '  "cvmRouter": "',
            vm.toString(routerProxy),
            '",\n',
            '  "cvmRouterImpl": "',
            vm.toString(routerImpl),
            '",\n',
            '  "useMockVerifier": ',
            useMock ? "true" : "false",
            ",\n",
            '  "registrationTtl": ',
            vm.toString(uint256(ttl)),
            ",\n",
            '  "proxyAdminOwner": "',
            vm.toString(dao),
            '"\n',
            "}\n"
        );
        vm.writeFile("deployments/base-sepolia-oracle.json", json);
    }
}
