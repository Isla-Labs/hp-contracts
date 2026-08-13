// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { ConstitutionalTimelock } from "@governance/ConstitutionalTimelock.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";

/**
 * @title DeployTimelock
 * @notice Deploy ConstitutionalTimelock and register `TIMELOCK` on AddressProvider.
 * @dev Must run before factories (beacons take TIMELOCK as UpgradeableBeacon owner).
 *      `minDelay == 0` → CT `DEFAULT_MIN_DELAY` (7 days). Testnet staged scripts pass 5 minutes.
 */
abstract contract DeployTimelock is AddressProviderOps {
    function _deployTimelock(address multisig, address deployer, uint256 minDelay) internal returns (address timelock) {
        if (multisig == address(0)) revert("multisig required");
        if (deployer == address(0)) revert("deployer required");
        _requireAddressProvider();

        timelock = address(new ConstitutionalTimelock(multisig, minDelay));
        _registerName(deployer, Keys.TIMELOCK, timelock);

        console.log("=== DeployTimelock ===");
        console.log("ConstitutionalTimelock", timelock);
        console.log("minDelay", minDelay);
        console.log("multisig (proposer)", multisig);
    }
}
