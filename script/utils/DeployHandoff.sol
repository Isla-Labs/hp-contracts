// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { AddressProvider } from "@src/AddressProvider.sol";

import { AddressProviderOps } from "./AddressProviderOps.sol";
import { ProxyUtils } from "./ProxyUtils.sol";

/**
 * @title DeployHandoff
 * @notice Step 9: transfer AddressProvider + ProxyAdmins to Orchestrator.
 * @dev Oracle proxy admins stay with OWNER (out of band). Call after factories.
 */
abstract contract DeployHandoff is AddressProviderOps, ProxyUtils {
    function _handoff(address deployer) internal {
        if (deployer == address(0)) revert("deployer required");

        AddressProvider ap = _requireAddressProvider();
        if (Ownable(address(ap)).owner() != deployer) {
            revert("AddressProvider owner must be deployer for handoff");
        }

        address orchestrator = _requireName(Keys.ORCHESTRATOR);
        address tournamentRegistry = _requireName(Keys.TOURNAMENT_REGISTRY);
        address playerSetRegistry = _requireName(Keys.PLAYER_SET_REGISTRY);
        address deployTournament = _requireName(Keys.DEPLOY_TOURNAMENT);

        // Soft-require lockers / factories so handoff can proceed if partial — but warn.
        // TEMP: ROUND_MANAGER parked with data plane — restore when DeployData returns.
        // _warnIfMissing(Keys.ROUND_MANAGER);
        _warnIfMissing(Keys.STAKE_VESTING);
        _warnIfMissing(Keys.DOPPLER_CONFIG);
        _warnIfMissing(Keys.DOPPLER_LOCKER);
        _warnIfMissing(Keys.TRANSFER_LOCKER);
        _warnIfMissing(Keys.FEE_ROUTER_FACTORY);
        _warnIfMissing(Keys.PLAYER_VAULT_FACTORY);
        _warnIfMissing(Keys.PBR_TREASURY_FACTORY);
        _warnIfMissing(Keys.PBR_FEE_HUB_FACTORY);

        Ownable(address(ap)).transferOwnership(orchestrator);
        _transferProxyAdmin(tournamentRegistry, orchestrator);
        _transferProxyAdmin(playerSetRegistry, orchestrator);
        _transferProxyAdmin(deployTournament, orchestrator);
        // _transferProxyAdminIfSet(Keys.ROUND_MANAGER, orchestrator);

        _transferProxyAdminIfSet(Keys.STAKE_VESTING, orchestrator);
        _transferProxyAdminIfSet(Keys.DOPPLER_CONFIG, orchestrator);
        _transferProxyAdminIfSet(Keys.DOPPLER_LOCKER, orchestrator);
        _transferProxyAdminIfSet(Keys.TRANSFER_LOCKER, orchestrator);
        _transferProxyAdminIfSet(Keys.FEE_ROUTER_FACTORY, orchestrator);
        _transferProxyAdminIfSet(Keys.PLAYER_VAULT_FACTORY, orchestrator);
        _transferProxyAdminIfSet(Keys.PBR_TREASURY_FACTORY, orchestrator);
        _transferProxyAdminIfSet(Keys.PBR_FEE_HUB_FACTORY, orchestrator);

        console.log("=== DeployHandoff ===");
        console.log("AddressProvider owner -> Orchestrator", orchestrator);
        console.log("ProxyAdmins transferred for registries / DT / StakeVesting / lockers / factories");
    }

    function _transferProxyAdminIfSet(string memory name, address newOwner) internal {
        address proxy = _requireAddressProvider().getByName(name);
        if (proxy == address(0)) return;
        _transferProxyAdmin(proxy, newOwner);
    }

    function _warnIfMissing(string memory name) internal view {
        address addr = _requireAddressProvider().getByName(name);
        if (addr == address(0)) {
            console.log("WARN: missing on AddressProvider before handoff:", name);
        }
    }
}
