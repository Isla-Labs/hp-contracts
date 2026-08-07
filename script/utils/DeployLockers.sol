// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { DopplerConfig } from "@deployments/assets/deploy/config/DopplerConfig.sol";
import { DopplerLocker } from "@deployments/assets/deploy/DopplerLocker.sol";
import { TransferLocker } from "@deployments/assets/transfer/TransferLocker.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";
import { ProxyUtils } from "./ProxyUtils.sol";

/**
 * @title DeployLockers
 * @notice DopplerConfig + DopplerLocker + TransferLocker (TUP); register; initialize.
 * @dev ProxyAdmin stays with deployer until DeployHandoff.
 *      Deploy `DopplerConfig` first so `DopplerLocker.initialize` can resolve it.
 */
abstract contract DeployLockers is AddressProviderOps, ProxyUtils {
    struct LockerDeployment {
        address dopplerConfig;
        address dopplerLocker;
        address transferLocker;
        address dopplerConfigImpl;
        address dopplerLockerImpl;
        address transferLockerImpl;
        address initGuard;
    }

    function _deployLockers(address deployer) internal returns (LockerDeployment memory d) {
        if (deployer == address(0)) revert("deployer required");

        address addressProvider = address(_requireAddressProvider());
        _requireName(Keys.ORCHESTRATOR);
        _requireName(Keys.CVM_ROUTER);
        _requireName(Keys.PLAYER_SET_REGISTRY);
        _requireName(Keys.TOURNAMENT_REGISTRY);

        InitGuard guard = new InitGuard();
        d.initGuard = address(guard);

        d.dopplerConfig = _deployInitGuardProxy(guard, deployer);
        d.dopplerLocker = _deployInitGuardProxy(guard, deployer);
        d.transferLocker = _deployInitGuardProxy(guard, deployer);

        d.dopplerConfigImpl = address(new DopplerConfig(addressProvider));
        d.dopplerLockerImpl = address(new DopplerLocker(addressProvider));
        d.transferLockerImpl = address(new TransferLocker(addressProvider));

        _registerName(deployer, Keys.DOPPLER_CONFIG, d.dopplerConfig);
        _registerName(deployer, Keys.DOPPLER_LOCKER, d.dopplerLocker);
        _registerName(deployer, Keys.TRANSFER_LOCKER, d.transferLocker);

        _upgradeAndCall(d.dopplerConfig, d.dopplerConfigImpl, abi.encodeCall(DopplerConfig.initialize, ()));
        _upgradeAndCall(d.dopplerLocker, d.dopplerLockerImpl, abi.encodeCall(DopplerLocker.initialize, ()));
        _upgradeAndCall(d.transferLocker, d.transferLockerImpl, abi.encodeCall(TransferLocker.initialize, ()));

        console.log("=== DeployLockers (proxies) ===");
        console.log("DopplerConfig", d.dopplerConfig);
        console.log("DopplerLocker", d.dopplerLocker);
        console.log("TransferLocker", d.transferLocker);
    }
}
