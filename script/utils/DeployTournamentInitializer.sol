// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { TournamentInitializer } from "@initializers/tournaments/TournamentInitializer.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";

/**
 * @title DeployTournamentInitializer
 * @notice Immutable TournamentInitializer; register `TOURNAMENT_INITIALIZER` on AddressProvider.
 */
abstract contract DeployTournamentInitializer is AddressProviderOps {
    function _deployTournamentInitializer(address deployer) internal returns (address tournamentInitializer) {
        if (deployer == address(0)) revert("deployer required");
        address addressProvider = address(_requireAddressProvider());

        tournamentInitializer = address(new TournamentInitializer(addressProvider));
        _registerName(deployer, Keys.TOURNAMENT_INITIALIZER, tournamentInitializer);

        console.log("=== DeployTournamentInitializer (immutable) ===");
        console.log("TOURNAMENT_INITIALIZER", tournamentInitializer);
    }
}
