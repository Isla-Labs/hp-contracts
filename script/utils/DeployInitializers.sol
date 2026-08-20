// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { MigrationListener } from "@data/markets/MigrationListener.sol";
import { LifecycleManager } from "@initializers/lifecycle/LifecycleManager.sol";
import { DopplerConfig } from "@initializers/markets/base/DopplerConfig.sol";
import { MarketInitializer } from "@initializers/markets/MarketInitializer.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";
import { CvmRequesterOps } from "./CvmRequesterOps.sol";

/**
 * @title DeployInitializers
 * @notice Immutable DopplerConfig + MarketInitializer + LifecycleManager + MigrationListener.
 * @dev `CVM_ROUTER` must already be on AddressProvider (Oracle-binding ctors).
 */
abstract contract DeployInitializers is AddressProviderOps, CvmRequesterOps {
    struct InitializerDeployment {
        address dopplerConfig;
        address marketInitializer;
        address lifecycleManager;
        address migrationListener;
    }

    function _deployInitializers(address deployer) internal returns (InitializerDeployment memory d) {
        if (deployer == address(0)) revert("deployer required");
        address addressProvider = address(_requireAddressProvider());
        _requireName(Keys.CVM_ROUTER);

        d.dopplerConfig = address(new DopplerConfig(addressProvider));
        d.marketInitializer = address(new MarketInitializer(addressProvider));
        d.lifecycleManager = address(new LifecycleManager(addressProvider));
        d.migrationListener = address(new MigrationListener(addressProvider, 0));

        _registerName(deployer, Keys.DOPPLER_CONFIG, d.dopplerConfig);
        _registerName(deployer, Keys.MARKET_INITIALIZER, d.marketInitializer);
        _registerName(deployer, Keys.LIFECYCLE_MANAGER, d.lifecycleManager);
        _registerName(deployer, Keys.MIGRATION_LISTENER, d.migrationListener);

        address router = _requireName(Keys.CVM_ROUTER);
        _allowCvmRequester(router, d.marketInitializer);
        _allowCvmRequester(router, d.lifecycleManager);
        _allowCvmRequester(router, d.migrationListener);

        console.log("=== DeployInitializers (immutable) ===");
        console.log("DOPPLER_CONFIG", d.dopplerConfig);
        console.log("MARKET_INITIALIZER", d.marketInitializer);
        console.log("LIFECYCLE_MANAGER", d.lifecycleManager);
        console.log("MIGRATION_LISTENER", d.migrationListener);
    }
}
