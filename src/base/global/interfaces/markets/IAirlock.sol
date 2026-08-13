// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IAirlock
 * @notice Narrow Doppler Airlock surface used by migration sync (avoids Quoter solc pin).
 */
interface IAirlock {
    function migrate(address asset) external;
}
