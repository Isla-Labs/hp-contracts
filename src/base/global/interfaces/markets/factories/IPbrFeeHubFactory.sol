// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IPbrFeeHubFactory
 * @notice Cross-contract surface for per-domestic-league `PbrFeeHub` deploys.
 */
interface IPbrFeeHubFactory {
    function deployTournament() external view returns (address);

    function create(bytes32 leagueId, address leagueTreasury) external returns (address hub);

    function implementation() external view returns (address);
}
