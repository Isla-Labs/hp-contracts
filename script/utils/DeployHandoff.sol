// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { AddressProvider } from "@src/AddressProvider.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";

/**
 * @title DeployHandoff
 * @notice Post-bootstrap sanity checks around AddressProvider admin → ConstitutionalTimelock.
 * @dev Protocol cores are immutable — there are no ProxyAdmins to transfer. Oracle TUPs stay
 *      with OWNER out of band. Factory beacons are owned by AP `TIMELOCK` (ConstitutionalTimelock)
 *      from construction.
 */
abstract contract DeployHandoff is AddressProviderOps {
    /// @notice Staged-script entry: transfer AP admin to TIMELOCK when deployer still holds it.
    function _handoff(address deployer) internal {
        AddressProvider ap = _requireAddressProvider();
        address timelock = ap.getByName(Keys.TIMELOCK);
        if (ap.hasRole(ap.DEFAULT_ADMIN_ROLE(), deployer)) {
            _handoffPreTransfer(deployer);
            if (timelock == address(0)) revert("TIMELOCK missing - deploy ConstitutionalTimelock first");
            ap.transferDefaultAdmin(timelock);
            console.log("AddressProvider DEFAULT_ADMIN -> ConstitutionalTimelock", timelock);
            _handoffPostTransfer(timelock);
            return;
        }
        if (timelock != address(0) && ap.hasRole(ap.DEFAULT_ADMIN_ROLE(), timelock)) {
            _handoffPostTransfer(timelock);
            return;
        }
        revert("AddressProvider DEFAULT_ADMIN is neither deployer nor TIMELOCK");
    }

    /// @notice Pre-transfer: deployer must still hold DEFAULT_ADMIN; required names must exist.
    function _handoffPreTransfer(address deployer) internal view {
        if (deployer == address(0)) revert("deployer required");

        AddressProvider ap = _requireAddressProvider();
        if (!ap.hasRole(ap.DEFAULT_ADMIN_ROLE(), deployer)) {
            revert("AddressProvider DEFAULT_ADMIN must be deployer before transfer");
        }

        _requireName(Keys.TIMELOCK);
        _requireName(Keys.ORCHESTRATOR);
        _requireName(Keys.TOURNAMENT_REGISTRY);
        _requireName(Keys.PLAYER_SET_REGISTRY);
        _requireName(Keys.STAKE_VESTING);
        _requireName(Keys.FEE_ROUTER_FACTORY);
        _requireName(Keys.PLAYER_VAULT_FACTORY);
        _requireName(Keys.PBR_TREASURY_FACTORY);
        _requireName(Keys.PBR_FEE_HUB_FACTORY);
        _requireName(Keys.DOPPLER_CONFIG);
        _requireName(Keys.TOURNAMENT_INITIALIZER);
        _requireName(Keys.MARKET_INITIALIZER);
        _requireName(Keys.LIFECYCLE_MANAGER);
        _requireName(Keys.MIGRATION_LISTENER);
        _requireName(Keys.ROUND_MANAGER);
        _requireName(Keys.SQUAD_STORE);
        _requireName(Keys.ELIGIBILITY_VERIFIER);
        _requireName(Keys.PBR_HISTORICAL);
        _requireName(Keys.PBR_SETTLE);

        // Routers optional on mainnet staged path; DeployAll always registers them on Sepolia.
        _warnIfMissing(Keys.STAKE_ROUTER);
        _warnIfMissing(Keys.TRADE_ROUTER);
        _warnIfMissing(Keys.Z_ROUTER);
        _warnIfMissing(Keys.Z_QUOTER);

        console.log("=== DeployHandoff (pre-transfer) ===");
        console.log("AddressProvider DEFAULT_ADMIN is deployer; transferring to TIMELOCK next");
        console.log("No protocol ProxyAdmins (immutable core) - oracle ProxyAdmins unchanged");
    }

    function _warnIfMissing(string memory name) internal view {
        address addr = _requireAddressProvider().getByName(name);
        if (addr == address(0)) {
            console.log("WARN: missing on AddressProvider before handoff:", name);
        }
    }

    /// @notice Post-transfer: ConstitutionalTimelock must be sole DEFAULT_ADMIN.
    function _handoffPostTransfer(address constitutionalTimelock) internal view {
        if (constitutionalTimelock == address(0)) revert("constitutionalTimelock required");

        AddressProvider ap = _requireAddressProvider();
        address timelock = ap.getByName(Keys.TIMELOCK);
        if (timelock != constitutionalTimelock) {
            revert("TIMELOCK on AddressProvider must equal ConstitutionalTimelock");
        }
        if (!ap.hasRole(ap.DEFAULT_ADMIN_ROLE(), constitutionalTimelock)) {
            revert("AddressProvider DEFAULT_ADMIN must be ConstitutionalTimelock after transfer");
        }

        console.log("=== DeployHandoff (post-transfer) ===");
        console.log("AddressProvider DEFAULT_ADMIN -> ConstitutionalTimelock", constitutionalTimelock);
        console.log("Factory beacons owned by TIMELOCK (ConstitutionalTimelock)");
    }
}
