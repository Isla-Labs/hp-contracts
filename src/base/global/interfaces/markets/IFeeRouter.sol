// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PlayerStatus } from "@types/registries/PlayerSetTypes.sol";

/**
 * @title IFeeRouter
 * @notice Cross-contract surface for per-market fee relays.
 */
interface IFeeRouter {
    function pbrFeeHub() external view returns (address);

    function setStatus(PlayerStatus status_) external;

    function setPbrFeeHub(address newHub) external;
}
