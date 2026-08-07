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

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { AddressProviderOps } from "../utils/AddressProviderOps.sol";
import { ProxyUtils } from "../utils/ProxyUtils.sol";

/**
 * @title DeployOracle
 * @notice Base Sepolia bootstrap: upgradeable CvmCoordinator + CvmRouter (Transparent proxies).
 * @dev Hybrid: Phala DstackApp/KMS on Ethereum (out of band). This stack is attestation registry
 *      + request bus only — stable proxy addresses so CVM sealed env need not change on upgrades.
 *
 *      ProxyAdmin owner = OWNER/deployer initially.
 *      If ADDRESS_PROVIDER is set and owned by deployer, registers CVM_COORDINATOR + CVM_ROUTER.
 *
 *      Makefile: `make deploy-base-sepolia-oracle`
 *
 *      Env:
 *        PRIVATE_KEY, OWNER_ADDRESS (fallback DAO_ADDRESS)
 *        ADDRESS_PROVIDER (optional — auto-register CVM names)
 *        USE_MOCK_VERIFIER (default false — Automata DCAP; set true for local/unit bring-up)
 *        REGISTRATION_TTL (default 1 day)
 *        MAX_QUOTE_AGE (default 1 hour)
 *        COMPOSE_HASH (optional immediate allowlist)
 */
contract DeployOracle is Script, ProxyUtils, AddressProviderOps {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address owner = vm.envOr("OWNER_ADDRESS", vm.envOr("DAO_ADDRESS", deployer));

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

        address coordinatorProxy = _deployInitGuardProxy(guard, owner);
        address coordinatorImpl = address(new CvmCoordinator());
        _upgradeAndCall(
            coordinatorProxy, coordinatorImpl, abi.encodeCall(CvmCoordinator.initialize, (owner, verifier, ttl))
        );

        if (owner == deployer && vm.envExists("COMPOSE_HASH")) {
            CvmCoordinator(coordinatorProxy).addComposeHash(vm.envBytes32("COMPOSE_HASH"));
        }

        CvmRouterConfig memory routerConfig = CvmRouterConfig({
            // Headroom for one-club squad upserts (Base per-tx cap ~16.7M; raise later if needed).
            maxCallbackGasLimit: 5_000_000,
            requestTimeout: uint32(1 hours),
            gasForCallExactCheck: 5000
        });

        address routerProxy = _deployInitGuardProxy(guard, owner);
        address routerImpl = address(new CvmRouter());
        _upgradeAndCall(
            routerProxy, routerImpl, abi.encodeCall(CvmRouter.initialize, (owner, coordinatorProxy, routerConfig))
        );

        _tryRegisterName(deployer, Keys.CVM_COORDINATOR, coordinatorProxy);
        _tryRegisterName(deployer, Keys.CVM_ROUTER, routerProxy);

        vm.stopBroadcast();

        console2.log("InitGuard", address(guard));
        console2.log("AttestationVerifier", verifier);
        console2.log("CvmCoordinator proxy", coordinatorProxy);
        console2.log("CvmCoordinator impl", coordinatorImpl);
        console2.log("CvmRouter proxy", routerProxy);
        console2.log("CvmRouter impl", routerImpl);
        console2.log("ProxyAdmin owner", owner);
        console2.log("useMockVerifier", useMock);
        if (_addressProviderOrZero() == address(0)) {
            console2.log("ADDRESS_PROVIDER unset - register CVM_* later via staging script:set-address");
        }

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
            vm.toString(owner),
            '"\n',
            "}\n"
        );
        vm.writeFile("deployments/base-sepolia-oracle.json", json);
    }
}
