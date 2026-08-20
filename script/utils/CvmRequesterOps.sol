// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { AddressProvider } from "@src/AddressProvider.sol";
import { CvmRouter } from "@src/oracle/CvmRouter.sol";

/**
 * @title CvmRequesterOps
 * @notice Allowlist HP oracle consumers on `CvmRouter` after they are deployed.
 */
abstract contract CvmRequesterOps {
    function _allowCvmRequester(address router, address consumer) internal {
        if (router == address(0)) revert("CVM_ROUTER required to allow requester");
        if (consumer == address(0)) revert("cannot allow zero requester");
        CvmRouter(router).setRequester(consumer, true);
        console.log("CvmRouter requester", consumer);
    }

    /// @notice Allow every known Oracle child currently registered on `ap` (skips unset slots).
    function _seedCvmRequesters(address router, AddressProvider ap) internal {
        if (router == address(0) || address(ap) == address(0)) return;

        _allowIfSet(router, ap, Keys.SQUAD_STORE);
        _allowIfSet(router, ap, Keys.ROUND_MANAGER);
        _allowIfSet(router, ap, Keys.PBR_HISTORICAL);
        _allowIfSet(router, ap, Keys.PBR_SETTLE);
        _allowIfSet(router, ap, Keys.MARKET_INITIALIZER);
        _allowIfSet(router, ap, Keys.LIFECYCLE_MANAGER);
        _allowIfSet(router, ap, Keys.MIGRATION_LISTENER);
    }

    function _allowIfSet(address router, AddressProvider ap, string memory name) private {
        address consumer = ap.getByName(name);
        if (consumer == address(0)) return;
        _allowCvmRequester(router, consumer);
    }
}
