// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IPbrTreasuryFactory
 * @notice Cross-contract surface for per-tournament `PbrTreasury` CREATE3 deploys.
 */
interface IPbrTreasuryFactory {
    function orchestrator() external view returns (address);

    function create(bytes32 tournamentId, uint16 initialSeason, bytes32 salt) external returns (address pbrTreasury);

    function makeSalt(bytes11 entropy) external view returns (bytes32);

    function computeGuardedSalt(bytes32 salt) external view returns (bytes32);

    function computeCreate3Address(bytes32 salt) external view returns (address);

    function implementation() external view returns (address);
}
