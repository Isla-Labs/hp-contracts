// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { DopplerLocker } from "@deployments/assets/deploy/DopplerLocker.sol";
import { TransferLocker } from "@deployments/assets/transfer/TransferLocker.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";

/**
 * @title DeployLockers
 * @notice Step 7: DopplerLocker + TransferLocker; register on AddressProvider.
 */
abstract contract DeployLockers is AddressProviderOps {
    struct LockerDeployment {
        address dopplerLocker;
        address transferLocker;
    }

    function _deployLockers(address deployer) internal returns (LockerDeployment memory d) {
        if (deployer == address(0)) revert("deployer required");
        _requireAddressProvider();

        address orchestrator = _requireName(Keys.ORCHESTRATOR);
        address cvmRouter = _requireName(Keys.CVM_ROUTER);
        address playerSetRegistry = _requireName(Keys.PLAYER_SET_REGISTRY);
        address tournamentRegistry = _requireName(Keys.TOURNAMENT_REGISTRY);

        d.dopplerLocker = address(new DopplerLocker(orchestrator, cvmRouter, 24 hours, 5 minutes));
        d.transferLocker = address(new TransferLocker(orchestrator, playerSetRegistry, tournamentRegistry));

        _registerName(deployer, Keys.DOPPLER_LOCKER, d.dopplerLocker);
        _registerName(deployer, Keys.TRANSFER_LOCKER, d.transferLocker);

        console.log("=== DeployLockers ===");
        console.log("DopplerLocker", d.dopplerLocker);
        console.log("TransferLocker", d.transferLocker);
    }
}
