// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IPbrTreasuryFactory
 * @notice Cross-contract surface for per-tournament `PbrTreasury` CREATE3 deploys.
 */
interface IPbrTreasuryFactory {
    function create(
        bytes32 tournamentId,
        uint16 initialSeasonStartYear,
        bytes32 salt
    ) external returns (address pbrTreasury);

    function implementation() external view returns (address);
}
