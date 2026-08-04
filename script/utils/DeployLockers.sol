// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { DopplerLocker } from "@deployments/assets/deploy/DopplerLocker.sol";
import { TransferLocker } from "@deployments/assets/transfer/TransferLocker.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";
import { ProxyUtils } from "./ProxyUtils.sol";

/**
 * @title DeployLockers
 * @notice Step 7: DopplerLocker + TransferLocker (TUP); register on AddressProvider.
 * @dev ProxyAdmin stays with deployer until DeployHandoff.
 */
abstract contract DeployLockers is AddressProviderOps, ProxyUtils {
    struct LockerDeployment {
        address dopplerLocker;
        address transferLocker;
        address dopplerLockerImpl;
        address transferLockerImpl;
        address initGuard;
    }

    function _deployLockers(address deployer) internal returns (LockerDeployment memory d) {
        if (deployer == address(0)) revert("deployer required");
        _requireAddressProvider();

        address orchestrator = _requireName(Keys.ORCHESTRATOR);
        address cvmRouter = _requireName(Keys.CVM_ROUTER);
        address playerSetRegistry = _requireName(Keys.PLAYER_SET_REGISTRY);
        address tournamentRegistry = _requireName(Keys.TOURNAMENT_REGISTRY);

        InitGuard guard = new InitGuard();
        d.initGuard = address(guard);

        d.dopplerLocker = _deployInitGuardProxy(guard, deployer);
        d.transferLocker = _deployInitGuardProxy(guard, deployer);

        d.dopplerLockerImpl = address(new DopplerLocker(cvmRouter, 5 minutes));
        d.transferLockerImpl = address(new TransferLocker(playerSetRegistry, tournamentRegistry));

        _registerName(deployer, Keys.DOPPLER_LOCKER, d.dopplerLocker);
        _registerName(deployer, Keys.TRANSFER_LOCKER, d.transferLocker);

        _upgradeAndCall(
            d.dopplerLocker,
            d.dopplerLockerImpl,
            abi.encodeCall(DopplerLocker.initialize, (orchestrator, 24 hours))
        );
        _upgradeAndCall(
            d.transferLocker, d.transferLockerImpl, abi.encodeCall(TransferLocker.initialize, (orchestrator))
        );

        console.log("=== DeployLockers (proxies) ===");
        console.log("DopplerLocker", d.dopplerLocker);
        console.log("TransferLocker", d.transferLocker);
    }
}
