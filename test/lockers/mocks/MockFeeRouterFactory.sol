// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { MockFeeRouter } from "./MockFeeRouter.sol";

contract MockFeeRouterFactory {
    mapping(bytes32 playerId => address) public feeRouterOf;

    function create(bytes32 playerId, address pbrFeeHub) external returns (address feeRouter) {
        feeRouter = feeRouterOf[playerId];
        if (feeRouter != address(0)) return feeRouter;

        MockFeeRouter router = new MockFeeRouter();
        router.setPbrFeeHub(pbrFeeHub);
        feeRouter = address(router);
        feeRouterOf[playerId] = feeRouter;
    }
}
