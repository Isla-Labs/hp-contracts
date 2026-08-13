// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

contract MockFeeRouter {
    address public pbrFeeHub;

    function setPbrFeeHub(address hub) external {
        pbrFeeHub = hub;
    }
}
