// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { DeployTournament } from "@deployments/tournaments/DeployTournament.sol";
import { FeeRouterFactory } from "@markets/factories/FeeRouterFactory.sol";
import { PbrFeeHubFactory } from "@markets/factories/PbrFeeHubFactory.sol";
import { PbrTreasuryFactory } from "@vaults/factories/PbrTreasuryFactory.sol";
import { PlayerVaultFactory } from "@vaults/factories/PlayerVaultFactory.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";
import { ProxyUtils } from "./ProxyUtils.sol";

/**
 * @title DeployFactories
 * @notice Step 8: upgradeable market + vault beacon factories; configure DeployTournament; register on AP.
 * @dev InitGuard TUP per factory; ProxyAdmin stays with deployer until DeployHandoff.
 */
abstract contract DeployFactories is AddressProviderOps, ProxyUtils {
    struct FactoryDeployment {
        address feeRouterFactory;
        address pbrFeeHubFactory;
        address pbrTreasuryFactory;
        address playerVaultFactory;
        address feeRouterFactoryImpl;
        address pbrFeeHubFactoryImpl;
        address pbrTreasuryFactoryImpl;
        address playerVaultFactoryImpl;
        address initGuard;
    }

    function _deployFactories(address deployer) internal returns (FactoryDeployment memory f) {
        if (deployer == address(0)) revert("deployer required");

        address addressProvider = address(_requireAddressProvider());
        address deployTournament = _requireName(Keys.DEPLOY_TOURNAMENT);
        _requireName(Keys.ORCHESTRATOR);

        address owner = _ownerOrDeployer(deployer);

        InitGuard guard = new InitGuard();
        f.initGuard = address(guard);

        f.feeRouterFactory = _deployInitGuardProxy(guard, deployer);
        f.playerVaultFactory = _deployInitGuardProxy(guard, deployer);
        f.pbrTreasuryFactory = _deployInitGuardProxy(guard, deployer);
        f.pbrFeeHubFactory = _deployInitGuardProxy(guard, deployer);

        f.feeRouterFactoryImpl = address(new FeeRouterFactory(addressProvider));
        f.playerVaultFactoryImpl = address(new PlayerVaultFactory(addressProvider));
        f.pbrTreasuryFactoryImpl = address(new PbrTreasuryFactory(addressProvider));
        f.pbrFeeHubFactoryImpl = address(new PbrFeeHubFactory(addressProvider));

        // Register before initialize (initialize resolves Orchestrator from AP; names are for ops).
        _registerName(deployer, Keys.FEE_ROUTER_FACTORY, f.feeRouterFactory);
        _registerName(deployer, Keys.PLAYER_VAULT_FACTORY, f.playerVaultFactory);
        _registerName(deployer, Keys.PBR_TREASURY_FACTORY, f.pbrTreasuryFactory);
        _registerName(deployer, Keys.PBR_FEE_HUB_FACTORY, f.pbrFeeHubFactory);

        _upgradeAndCall(f.feeRouterFactory, f.feeRouterFactoryImpl, abi.encodeCall(FeeRouterFactory.initialize, ()));
        _upgradeAndCall(
            f.playerVaultFactory, f.playerVaultFactoryImpl, abi.encodeCall(PlayerVaultFactory.initialize, ())
        );
        _upgradeAndCall(
            f.pbrTreasuryFactory, f.pbrTreasuryFactoryImpl, abi.encodeCall(PbrTreasuryFactory.initialize, ())
        );
        _upgradeAndCall(f.pbrFeeHubFactory, f.pbrFeeHubFactoryImpl, abi.encodeCall(PbrFeeHubFactory.initialize, ()));

        if (deployer == owner) {
            DeployTournament(deployTournament).configureFactories(f.pbrTreasuryFactory, f.pbrFeeHubFactory);
        } else {
            console.log("OWNER != deployer: call DeployTournament.configureFactories(treasury, feeHub)");
        }

        console.log("=== DeployFactories (proxies) ===");
        console.log("FeeRouterFactory", f.feeRouterFactory);
        console.log("PlayerVaultFactory", f.playerVaultFactory);
        console.log("PbrTreasuryFactory", f.pbrTreasuryFactory);
        console.log("PbrFeeHubFactory", f.pbrFeeHubFactory);
    }
}
