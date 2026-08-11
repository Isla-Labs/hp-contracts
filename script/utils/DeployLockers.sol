// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { DopplerConfig } from "@deployments/assets/deploy/config/DopplerConfig.sol";
import { DopplerLocker } from "@deployments/assets/deploy/DopplerLocker.sol";
import { TransferLocker } from "@deployments/assets/transfer/TransferLocker.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";

/**
 * @title DeployLockers
 * @notice Immutable DopplerConfig + DopplerLocker + TransferLocker; register on AddressProvider.
 * @dev `CVM_ROUTER` must already be on AddressProvider (locker ctors bind it).
 *      Module / registry / factory deps resolve via AddressBook at call time.
 */
abstract contract DeployLockers is AddressProviderOps {
    struct LockerDeployment {
        address dopplerConfig;
        address dopplerLocker;
        address transferLocker;
    }

    function _deployLockers(address deployer) internal returns (LockerDeployment memory d) {
        if (deployer == address(0)) revert("deployer required");

        address addressProvider = address(_requireAddressProvider());
        _requireName(Keys.ORCHESTRATOR);
        _requireName(Keys.CVM_ROUTER);
        _requireName(Keys.PLAYER_SET_REGISTRY);
        _requireName(Keys.TOURNAMENT_REGISTRY);

        d.dopplerConfig = address(new DopplerConfig(addressProvider));
        d.dopplerLocker = address(new DopplerLocker(addressProvider));
        d.transferLocker = address(new TransferLocker(addressProvider));

        _registerName(deployer, Keys.DOPPLER_CONFIG, d.dopplerConfig);
        _registerName(deployer, Keys.DOPPLER_LOCKER, d.dopplerLocker);
        _registerName(deployer, Keys.TRANSFER_LOCKER, d.transferLocker);

        console.log("=== DeployLockers (immutable) ===");
        console.log("DopplerConfig", d.dopplerConfig);
        console.log("DopplerLocker", d.dopplerLocker);
        console.log("TransferLocker", d.transferLocker);
    }
}
