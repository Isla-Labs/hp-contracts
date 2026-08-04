// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { RoundManager } from "@data/matchweeks/RoundManager.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";
import { ProxyUtils } from "./ProxyUtils.sol";

/**
 * @title DeployData
 * @notice Step 6: RoundManager calendar SoT (EligibilityStore / Verifier later).
 */
abstract contract DeployData is AddressProviderOps, ProxyUtils {
    struct DataDeployment {
        address roundManager;
        address roundManagerImpl;
        address initGuard;
    }

    function _deployData(address deployer) internal returns (DataDeployment memory d) {
        if (deployer == address(0)) revert("deployer required");

        address addressProvider = address(_requireAddressProvider());
        _requireName(Keys.ORCHESTRATOR);
        _requireName(Keys.TOURNAMENT_REGISTRY);

        InitGuard guard = new InitGuard();
        d.initGuard = address(guard);

        d.roundManager = _deployInitGuardProxy(guard, deployer);
        d.roundManagerImpl = address(new RoundManager(addressProvider));

        _registerName(deployer, Keys.ROUND_MANAGER, d.roundManager);

        _upgradeAndCall(d.roundManager, d.roundManagerImpl, abi.encodeCall(RoundManager.initialize, ()));

        console.log("=== DeployData (RoundManager) ===");
        console.log("RoundManager (proxy)", d.roundManager);
        console.log("RoundManager (impl)", d.roundManagerImpl);
    }
}
