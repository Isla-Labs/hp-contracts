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
 * @notice Market + vault factories; register on AP; initialize DeployTournament.
 * @dev FeeRouter / PbrFeeHub factories remain InitGuard TUPs (ProxyAdmin → Orchestrator at handoff).
 *      PlayerVault / PbrTreasury factories are immutable (`new` after ORCHESTRATOR is on AP).
 *      DeployTournament initialize runs here so factory names already exist on AddressProvider.
 */
abstract contract DeployFactories is AddressProviderOps, ProxyUtils {
    struct FactoryDeployment {
        address feeRouterFactory;
        address pbrFeeHubFactory;
        address pbrTreasuryFactory;
        address playerVaultFactory;
        address feeRouterFactoryImpl;
        address pbrFeeHubFactoryImpl;
        address deployTournamentImpl;
        address initGuard;
    }

    function _deployFactories(address deployer) internal returns (FactoryDeployment memory f) {
        if (deployer == address(0)) revert("deployer required");

        address addressProvider = address(_requireAddressProvider());
        address deployTournament = _requireName(Keys.DEPLOY_TOURNAMENT);
        _requireName(Keys.ORCHESTRATOR);
        _requireName(Keys.TIMELOCK);

        InitGuard guard = new InitGuard();
        f.initGuard = address(guard);

        f.feeRouterFactory = _deployInitGuardProxy(guard, deployer);
        f.pbrFeeHubFactory = _deployInitGuardProxy(guard, deployer);

        f.feeRouterFactoryImpl = address(new FeeRouterFactory(addressProvider));
        f.pbrFeeHubFactoryImpl = address(new PbrFeeHubFactory(addressProvider));

        // Immutable vault factories (constructor resolves Orchestrator + deploys beacons).
        f.playerVaultFactory = address(new PlayerVaultFactory(addressProvider));
        f.pbrTreasuryFactory = address(new PbrTreasuryFactory(addressProvider));

        _registerName(deployer, Keys.FEE_ROUTER_FACTORY, f.feeRouterFactory);
        _registerName(deployer, Keys.PLAYER_VAULT_FACTORY, f.playerVaultFactory);
        _registerName(deployer, Keys.PBR_TREASURY_FACTORY, f.pbrTreasuryFactory);
        _registerName(deployer, Keys.PBR_FEE_HUB_FACTORY, f.pbrFeeHubFactory);

        _upgradeAndCall(f.feeRouterFactory, f.feeRouterFactoryImpl, abi.encodeCall(FeeRouterFactory.initialize, ()));
        _upgradeAndCall(f.pbrFeeHubFactory, f.pbrFeeHubFactoryImpl, abi.encodeCall(PbrFeeHubFactory.initialize, ()));

        // DeployTournament resolves factories from AP — initialize only after the names above exist.
        f.deployTournamentImpl = address(new DeployTournament(addressProvider));
        _upgradeAndCall(deployTournament, f.deployTournamentImpl, abi.encodeCall(DeployTournament.initialize, ()));

        console.log("=== DeployFactories ===");
        console.log("FeeRouterFactory (proxy)", f.feeRouterFactory);
        console.log("PlayerVaultFactory (immutable)", f.playerVaultFactory);
        console.log("PbrTreasuryFactory (immutable)", f.pbrTreasuryFactory);
        console.log("PbrFeeHubFactory (proxy)", f.pbrFeeHubFactory);
        console.log("DeployTournament (impl)", f.deployTournamentImpl);
    }
}
