// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { AddressProvider } from "@src/AddressProvider.sol";

import { DeployRoutersLogic } from "../utils/DeployRoutersLogic.sol";

/**
 * @title DeployRouters
 * @notice Standalone / redeploy path for routers (also included in DeployAll before handoff).
 * @dev Prefer `make deploy-base-sepolia-all` for a full bootstrap. Use this target to redeploy
 *      routers against an existing AddressProvider (post-handoff → Orchestrator.execute).
 *
 *      Make: `make deploy-base-sepolia-routers`
 */
contract DeployRouters is DeployRoutersLogic {
    function run() external returns (RouterDeployment memory r) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        _loadConfigForCurrentChain();
        DeployContext memory context = _deployContext();
        require(_isConfiguredTestnet(context.chainId), "DeployRouters: expected testnet chain");

        address apAddr = _optionalConfigAddress(context.chainId, "address_provider");
        if (apAddr == address(0) && vm.envExists("ADDRESS_PROVIDER")) {
            apAddr = vm.envAddress("ADDRESS_PROVIDER");
        }
        require(apAddr != address(0), "DeployRouters: address_provider / ADDRESS_PROVIDER required");

        AddressProvider ap = AddressProvider(payable(apAddr));
        address orchestrator = ap.getByName(Keys.ORCHESTRATOR);
        require(orchestrator != address(0), "DeployRouters: ORCHESTRATOR missing");

        console.log("=== DeployRouters (standalone) ===");
        console.log("chainId", context.chainId);
        console.log("deployer", deployer);
        console.log("ADDRESS_PROVIDER", apAddr);
        console.log("ORCHESTRATOR", orchestrator);

        vm.startBroadcast(privateKey);
        r = _deployAndRegisterRouters(ap, orchestrator, deployer, context.chainId);
        _persistRouterOutputs(context, r);
        vm.stopBroadcast();

        console.log("=== DeployRouters complete ===");
        console.log("Z_ROUTER", r.zRouter);
        console.log("Z_QUOTER_BASE", r.zQuoterBase);
        console.log("Z_QUOTER (SDK)", r.zQuoter);
        console.log("STAKE_ROUTER", r.stakeRouter);
        console.log("TRADE_ROUTER", r.tradeRouter);
    }
}
