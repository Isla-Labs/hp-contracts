// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { StakeRouter } from "@routers/StakeRouter.sol";
import { TradeRouter } from "@routers/TradeRouter.sol";
import { ZQuoter } from "@routers/base-sepolia/ZQuoter.sol";
import { ZQuoterBase } from "@routers/base-sepolia/ZQuoterBase.sol";
import { ZRouter } from "@routers/base-sepolia/ZRouter.sol";
import { AddressProvider } from "@src/AddressProvider.sol";

import { HpDeployBase } from "./HpDeployBase.sol";

/**
 * @title DeployRoutersLogic
 * @notice Shared Base Sepolia router bootstrap used by DeployAll (pre–timelock AP handoff) and DeployRouters.
 */
abstract contract DeployRoutersLogic is HpDeployBase {
    struct RouterDeployment {
        address zRouter;
        address zQuoterBase;
        address zQuoter;
        address stakeRouter;
        address tradeRouter;
        address poolManager;
    }

    /// @dev Requires `PLAYER_SET_REGISTRY` already on AP. Self-deploys zAMM stack when all z_* are zero.
    function _deployAndRegisterRouters(
        AddressProvider ap,
        address orchestrator,
        address deployer,
        uint256 chainId
    ) internal returns (RouterDeployment memory r) {
        require(chainId == 84_532, "DeployRouters: Base Sepolia zAMM stack only");
        require(ap.getByName(Keys.PLAYER_SET_REGISTRY) != address(0), "DeployRouters: PLAYER_SET_REGISTRY missing");

        r.poolManager = _requireConfigAddress(chainId, "uniswap_v4_pool_manager");
        r.zRouter = _optionalConfigAddress(chainId, "z_router");
        r.zQuoter = _optionalConfigAddress(chainId, "z_quoter");
        r.zQuoterBase = _optionalConfigAddress(chainId, "z_quoter_base");

        console.log("--- deploy routers ---");
        console.log("POOL_MANAGER", r.poolManager);

        if (r.zRouter == address(0) || r.zQuoter == address(0) || r.zQuoterBase == address(0)) {
            require(
                r.zRouter == address(0) && r.zQuoter == address(0) && r.zQuoterBase == address(0),
                "DeployRouters: set all z_* or leave all zero for self-deploy"
            );
            r.zRouter = address(new ZRouter());
            r.zQuoterBase = address(new ZQuoterBase(r.zRouter));
            r.zQuoter = address(new ZQuoter(r.zQuoterBase, r.zRouter));
            console.log("Z_ROUTER deployed", r.zRouter);
            console.log("Z_QUOTER_BASE deployed", r.zQuoterBase);
            console.log("Z_QUOTER deployed", r.zQuoter);
        } else {
            console.log("Z_ROUTER from config", r.zRouter);
            console.log("Z_QUOTER_BASE from config", r.zQuoterBase);
            console.log("Z_QUOTER from config", r.zQuoter);
        }

        _setRouterName(ap, orchestrator, deployer, Keys.Z_ROUTER, r.zRouter);
        _setRouterName(ap, orchestrator, deployer, Keys.Z_QUOTER, r.zQuoter);

        r.stakeRouter = address(new StakeRouter(address(ap)));
        r.tradeRouter = address(new TradeRouter(address(ap), r.poolManager));
        _setRouterName(ap, orchestrator, deployer, Keys.STAKE_ROUTER, r.stakeRouter);
        _setRouterName(ap, orchestrator, deployer, Keys.TRADE_ROUTER, r.tradeRouter);
    }

    function _persistRouterOutputs(DeployContext memory context, RouterDeployment memory r) internal {
        _setConfigAddress(context, "z_router", r.zRouter);
        _setConfigAddress(context, "z_quoter_base", r.zQuoterBase);
        _setConfigAddress(context, "z_quoter", r.zQuoter);
        _setConfigAddress(context, "stake_router", r.stakeRouter);
        _setConfigAddress(context, "trade_router", r.tradeRouter);
    }

    /// @dev Direct `setName` while deployer holds AP `DEFAULT_ADMIN_ROLE`.
    ///      After `transferDefaultAdmin(ConstitutionalTimelock)`, register via timelock schedule/execute.
    function _setRouterName(
        AddressProvider ap,
        address, /* orchestrator */
        address deployer,
        string memory name,
        address addr
    ) internal {
        require(addr != address(0), string.concat("DeployRouters: zero ", name));
        require(
            ap.hasRole(ap.DEFAULT_ADMIN_ROLE(), deployer),
            "DeployRouters: deployer must be AddressProvider DEFAULT_ADMIN"
        );
        ap.setName(name, addr);
        console.log(name, addr);
    }
}
