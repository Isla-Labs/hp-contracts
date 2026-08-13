// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { StakeVesting } from "@governance/StakeVesting.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";

/**
 * @title DeployStakeVesting
 * @notice Immutable StakeVesting; register `STAKE_VESTING` on AddressProvider.
 * @dev Requires `HP_TREASURY` + `HP_MULTISIG` already seeded on AP.
 */
abstract contract DeployStakeVesting is AddressProviderOps {
    function _deployStakeVesting(address deployer) internal returns (address stakeVesting) {
        if (deployer == address(0)) revert("deployer required");
        address addressProvider = address(_requireAddressProvider());
        _requireName(Keys.HP_TREASURY);
        _requireName(Keys.HP_MULTISIG);

        stakeVesting = address(new StakeVesting(addressProvider));
        _registerName(deployer, Keys.STAKE_VESTING, stakeVesting);

        console.log("=== DeployStakeVesting (immutable) ===");
        console.log("STAKE_VESTING", stakeVesting);
    }
}
