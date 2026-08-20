// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { EligibilityVerifier } from "@data/eligibility/EligibilityVerifier.sol";
import { SquadStore } from "@data/eligibility/SquadStore.sol";
import { RoundManager } from "@data/matchweeks/RoundManager.sol";
import { PbrHistorical } from "@data/performances/PbrHistorical.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";
import { CvmRequesterOps } from "./CvmRequesterOps.sol";

/**
 * @title DeployData
 * @notice Immutable data plane: RoundManager, SquadStore, EligibilityVerifier, PbrHistorical.
 * @dev `CVM_ROUTER` required (Oracle-binding ctors). EligibilityVerifier cooldown is chainid-based
 *      (Base Sepolia 1m / else DEFAULT_COOLDOWN). Other modules use `0` → contract defaults.
 */
abstract contract DeployData is AddressProviderOps, CvmRequesterOps {
    struct DataDeployment {
        address roundManager;
        address squadStore;
        address eligibilityVerifier;
        address pbrHistorical;
    }

    function _deployData(address deployer) internal returns (DataDeployment memory d) {
        if (deployer == address(0)) revert("deployer required");
        address addressProvider = address(_requireAddressProvider());
        _requireName(Keys.CVM_ROUTER);

        d.roundManager = address(new RoundManager(addressProvider, 0));
        d.squadStore = address(new SquadStore(addressProvider, 0));
        d.eligibilityVerifier = address(new EligibilityVerifier(addressProvider));
        d.pbrHistorical = address(new PbrHistorical(addressProvider));

        _registerName(deployer, Keys.ROUND_MANAGER, d.roundManager);
        _registerName(deployer, Keys.SQUAD_STORE, d.squadStore);
        _registerName(deployer, Keys.ELIGIBILITY_VERIFIER, d.eligibilityVerifier);
        _registerName(deployer, Keys.PBR_HISTORICAL, d.pbrHistorical);

        address router = _requireName(Keys.CVM_ROUTER);
        _allowCvmRequester(router, d.roundManager);
        _allowCvmRequester(router, d.squadStore);
        _allowCvmRequester(router, d.pbrHistorical);

        console.log("=== DeployData (immutable) ===");
        console.log("ROUND_MANAGER", d.roundManager);
        console.log("SQUAD_STORE", d.squadStore);
        console.log("ELIGIBILITY_VERIFIER", d.eligibilityVerifier);
        console.log("PBR_HISTORICAL", d.pbrHistorical);
    }
}
